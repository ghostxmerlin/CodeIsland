import AppKit
import CodeIslandCore
import MeilingSoftKit

/// Software-mode dictation: talk key → mic → transcribe-live → each final sentence, after the learned
/// corrections, typed through the Meyrin input method and kept in the history. With the translate key the
/// sentences are gathered instead, and once the last one is in the whole paragraph goes to Gemini once
/// (MeilingTranslate); only the English reply is typed. Owns the engine (rebuilt when the key or the vocabulary
/// changes) and the typing queue.
@MainActor
final class MeilingSoftDictation {
    /// The talk is over from this side (a failed start, an error): the talk key's latch must be released.
    var onTalkEnded: (() -> Void)?

    private let committer = MeilingSoftCommitter()
    private let log = MeilingLog()
    private var engine: MeilingDictationEngine?
    private var engineKey = ""
    private var vocabularyDirty = false
    /// How the current (or last) talk's finals are used: kept until the next press, since the last final arrives
    /// after the release.
    private var english = false
    private var gather = MeilingTranslateGather(releaseTailMs: UInt64(MeilingDictationEngine.releaseTail * 1000))
    private var settle: DispatchWorkItem?
    /// Bumped by shutdown: a translation answering after that is dropped, not typed.
    private var translation = 0

    var talking: Bool { engine?.talking ?? false }

    /// A press; `english` for the translate key. False when it cannot start (no input method or key): the HUD
    /// says why.
    @discardableResult
    func start(english: Bool = false) -> Bool {
        guard MeilingInputSwitcher.installed else {
            MeilingSoftHUD.shared.error("Meyrin input method not installed or not enabled: Settings → Meyrin → Install")
            return false
        }
        guard let key = MeilingSoftSettings.apiKey() else {
            MeilingSoftHUD.shared.error("No Gemini API key: Settings → Meyrin → Gemini API Key")
            return false
        }
        if engine == nil || engineKey != key || vocabularyDirty {
            vocabularyDirty = false
            engine?.shutdown()
            engine = makeEngine(key)
            engineKey = key
        }
        if english {
            settle?.cancel()
            gather.resume()  // pressed again before the paragraph was sent: it goes on
        } else if gather.pending {
            log.write("soft: translate talk sent early (talk key pressed)")
            translateGathered()
        }
        self.english = english
        MeilingSoftHUD.shared.listening(english ? "Meyrin → English · \(MeilingSoftHotkey.key(.translate).name)"
                                                : "Meyrin Dictation · \(MeilingSoftHotkey.current.name)")
        engine?.begin(micName: MeilingSoftSettings.micName)
        if let mic = engine?.mic, mic.running { MeilingSoftHUD.shared.mic(mic.deviceName) }
        return true
    }

    /// Release: the engine records its 0.5 s tail, then the last sentence is finalized.
    func stop() {
        engine?.end()
        if english {
            gather.release(atMs: Self.nowMs())
            scheduleSettle()
        }
        MeilingSoftHUD.shared.stopped()
    }

    /// A chord or Esc: nothing of this talk is typed.
    func cancel() {
        engine?.cancel()
        committer.cancelPending()
        dropGather()  // a translation already sent belongs to an earlier talk and goes on
        MeilingSoftHUD.shared.interim("")
        MeilingSoftHUD.shared.stopped()
        log.write("soft: dictation cancelled (chord or Esc)")
    }

    /// Off, or the meeting takes the mic: the session closes and queued sentences are dropped.
    func shutdown() {
        committer.cancelPending()
        dropTranslation()
        engine?.shutdown()
        engine = nil
    }

    /// A new correction or list: the vocabulary is fixed at session setup, so the next press opens a new session.
    func vocabularyChanged() {
        guard let engine else { return }
        guard !engine.talking else {
            vocabularyDirty = true  // rebuilt on the next press (review C4)
            return
        }
        engine.shutdown()
        self.engine = nil
    }

    /// The engine's callbacks arrive on the main queue in order (its callbackQueue), hence assumeIsolated.
    private func makeEngine(_ key: String) -> MeilingDictationEngine {
        let engine = MeilingDictationEngine(
            apiKey: key, vocabulary: MeilingSoftSettings.vocabulary(corrections: MeilingCorrectionStore.shared.corrections))
        engine.mic.onLevel = { level in DispatchQueue.main.async { MainActor.assumeIsolated { MeilingSoftHUD.shared.level(level) } } }
        engine.onInterim = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, self.engine === engine, engine.talking else { return }
                MeilingSoftHUD.shared.interim(text)
            }
        }
        engine.onFinal = { [weak self] text, session in
            MainActor.assumeIsolated {
                // A cancelled talk's session is gone (cancel sets it to nil): its in-flight finals stop here.
                guard let self, self.engine === engine, engine.currentSession == session else {
                    MeilingDictationHistory.shared.add(text, source: "Mac", status: .cancelled)
                    self?.log.write("soft: final dropped (talk cancelled)")
                    return
                }
                if self.english {
                    self.gather.add(MeilingCorrectionStore.shared.apply(text), atMs: Self.nowMs())
                    self.scheduleSettle()
                } else {
                    self.type(text)
                }
            }
        }
        engine.onTalkSummary = { [weak self] line in MainActor.assumeIsolated { self?.log.write("soft: dictation \(line)") } }
        engine.onError = { [weak self] text in
            MainActor.assumeIsolated {
                self?.onTalkEnded?()
                if let self, self.english, self.gather.pending, self.gather.deadline == nil {
                    self.gather.release(atMs: Self.nowMs())  // the talk ended here (e.g. no mic): settle what it has
                    self.scheduleSettle()
                }
                MeilingSoftHUD.shared.stopped()  // not left "live" with a running timer (review C2)
                MeilingSoftHUD.shared.error(text)
                self?.log.write("soft: dictation error \(text)")
            }
        }
        engine.onState = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case let .failed(why), let .gaveUp(why):
                    MeilingSoftHUD.shared.error("Gemini: \(why)")
                    self?.log.write("soft: dictation session \(state)")
                case .ready, .connecting, .closed:
                    break
                }
            }
        }
        return engine
    }

    // MARK: into English

    private static func nowMs() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Waits for the gather's deadline, which a late final can move.
    private func scheduleSettle() {
        settle?.cancel()
        guard let deadline = gather.deadline else { return }
        let now = Self.nowMs()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let due = self.gather.deadline else { return }
            if Self.nowMs() < due { self.scheduleSettle() } else { self.translateGathered() }
        }
        settle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(deadline > now ? deadline - now : 0)), execute: item)
    }

    /// The talk is over: its paragraph → history (pending) → Gemini → the English is typed, or nothing is.
    private func translateGathered() {
        settle?.cancel()
        settle = nil
        guard let chinese = gather.take() else {
            log.write("soft: translate talk heard nothing")
            return
        }
        let history = MeilingDictationHistory.shared
        let id = history.add(chinese, source: "Mac", language: "en")
        let saved = "saved in Settings → Meyrin → History"
        guard let key = MeilingSoftSettings.apiKey() else {
            history.mark(id, .notTyped, note: "no Gemini API key")
            MeilingSoftHUD.shared.error("Not translated (no Gemini API key), \(saved): \(chinese)")
            return
        }
        translation += 1
        let mine = translation
        let started = Date()
        MeilingSoftHUD.shared.interim("Translating to English…")
        let terms = MeilingSoftSettings.vocabulary(corrections: MeilingCorrectionStore.shared.corrections)
        MeilingTranslateClient.translate(chinese, terminology: terms, apiKey: key) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, mine == self.translation else {
                    history.mark(id, .cancelled)
                    return
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch result {
                case let .success(english):
                    self.log.write("soft: translated \(ms) ms scalars=\(chinese.unicodeScalars.count)→\(english.unicodeScalars.count)")
                    history.setTyped(id, english)
                    self.commit(english, id: id)
                case let .failure(failure):
                    self.log.write("soft: translation failed after \(ms) ms: \(failure.reason)")
                    history.mark(id, .notTyped, note: "translation failed: \(failure.reason)")
                    MeilingSoftHUD.shared.interim("")
                    MeilingSoftHUD.shared.error("Not translated (\(failure.reason)), \(saved): \(chinese)")
                }
            }
        }
    }

    /// This talk is cancelled: what it gathered is not sent.
    private func dropGather() {
        settle?.cancel()
        settle = nil
        gather.cancel()
    }

    /// Off, or the meeting takes over: nothing gathered or still being translated is typed.
    private func dropTranslation() {
        dropGather()
        translation += 1
    }

    // MARK: typing

    /// Corrections → history → commit.
    private func type(_ heard: String) {
        let text = MeilingCorrectionStore.shared.apply(heard)
        if text != heard { log.write("soft: corrections applied") }
        let id = MeilingDictationHistory.shared.add(heard, typed: text, source: "Mac")
        commit(text, id: id)
    }

    /// The commit's outcome on the HUD, in the history and in the log.
    private func commit(_ text: String, id: UUID) {
        let history = MeilingDictationHistory.shared
        let saved = "saved in Settings → Meyrin → History"
        committer.commit(text) { [weak self] outcome in
            switch outcome {
            case .cancelled:
                history.mark(id, .cancelled)
                self?.log.write("soft: commit dropped (talk cancelled)")
            case let .ok(ms):
                history.mark(id, .typed)
                MeilingSoftHUD.shared.committed(text)
                self?.log.write("soft: commit ok \(ms) ms scalars=\(text.unicodeScalars.count)")
            case .notInstalled:
                history.mark(id, .notTyped, note: "input method not enabled")
                MeilingSoftHUD.shared.error("Not typed (Meyrin input method not installed or not enabled), \(saved): \(text)")
            case .inactive:
                history.mark(id, .notTyped, note: "no text field")
                MeilingSoftHUD.shared.error("Not typed (secure input, a password field, or no cursor), \(saved): \(text)")
                self?.log.write("soft: commit inactive after retries")
            case .unreachable:
                history.mark(id, .notTyped, note: "input method not responding")
                MeilingSoftHUD.shared.error("Not typed (Meyrin input method is not responding), \(saved): \(text)")
                self?.log.write("soft: commit unreachable")
            }
        }
    }
}
