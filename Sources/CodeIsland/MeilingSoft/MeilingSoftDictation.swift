import AppKit
import CodeIslandCore
import MeilingSoftKit

/// Software-mode dictation: talk key → mic → transcribe-live → each final sentence, after the learned
/// corrections, typed through the Meyrin input method and kept in the history. Owns the engine (rebuilt when the
/// key or the vocabulary changes) and the typing queue.
@MainActor
final class MeilingSoftDictation {
    /// The talk is over from this side (a failed start, an error): the talk key's latch must be released.
    var onTalkEnded: (() -> Void)?

    private let committer = MeilingSoftCommitter()
    private let log = MeilingLog()
    private var engine: MeilingDictationEngine?
    private var engineKey = ""
    private var vocabularyDirty = false

    var talking: Bool { engine?.talking ?? false }

    /// A press. False when it cannot start (no input method or key): the HUD says why.
    @discardableResult
    func start() -> Bool {
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
        MeilingSoftHUD.shared.listening("Meyrin Dictation · \(MeilingSoftHotkey.current.name)")
        engine?.begin(micName: MeilingSoftSettings.micName)
        if let mic = engine?.mic, mic.running { MeilingSoftHUD.shared.mic(mic.deviceName) }
        return true
    }

    /// Release: the engine records its 0.5 s tail, then the last sentence is finalized.
    func stop() {
        engine?.end()
        MeilingSoftHUD.shared.stopped()
    }

    /// A chord or Esc: nothing of this talk is typed.
    func cancel() {
        engine?.cancel()
        committer.cancelPending()
        MeilingSoftHUD.shared.interim("")
        MeilingSoftHUD.shared.stopped()
        log.write("soft: dictation cancelled (chord or Esc)")
    }

    /// Off, or the meeting takes the mic: the session closes and queued sentences are dropped.
    func shutdown() {
        committer.cancelPending()
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

    private func makeEngine(_ key: String) -> MeilingDictationEngine {
        let engine = MeilingDictationEngine(
            apiKey: key, vocabulary: MeilingSoftSettings.vocabulary(corrections: MeilingCorrectionStore.shared.corrections))
        engine.mic.onLevel = { level in Task { @MainActor in MeilingSoftHUD.shared.level(level) } }
        engine.onInterim = { [weak self] text in
            Task { @MainActor in
                guard let self, self.engine === engine, engine.talking else { return }
                MeilingSoftHUD.shared.interim(text)
            }
        }
        engine.onFinal = { [weak self] text, session in
            Task { @MainActor in
                // A cancelled talk's session is gone (cancel sets it to nil): its in-flight finals stop here.
                guard let self, self.engine === engine, engine.currentSession == session else {
                    MeilingDictationHistory.shared.add(text, source: "Mac", status: .cancelled)
                    self?.log.write("soft: final dropped (talk cancelled)")
                    return
                }
                self.type(text)
            }
        }
        engine.onTalkSummary = { [weak self] line in Task { @MainActor in self?.log.write("soft: dictation \(line)") } }
        engine.onError = { [weak self] text in
            Task { @MainActor in
                self?.onTalkEnded?()
                MeilingSoftHUD.shared.stopped()  // not left "live" with a running timer (review C2)
                MeilingSoftHUD.shared.error(text)
                self?.log.write("soft: dictation error \(text)")
            }
        }
        engine.onState = { [weak self] state in
            Task { @MainActor in
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

    /// Corrections → history → commit → the outcome on the HUD, in the history and in the log.
    private func type(_ heard: String) {
        let text = MeilingCorrectionStore.shared.apply(heard)
        if text != heard { log.write("soft: corrections applied") }
        let history = MeilingDictationHistory.shared
        let id = history.add(heard, typed: text, source: "Mac")
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
