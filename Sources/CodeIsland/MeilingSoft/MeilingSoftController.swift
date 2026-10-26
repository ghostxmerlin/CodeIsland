import AppKit
import AVFoundation
import CodeIslandCore
import MeilingSoftKit

/// 美玲 without the Tab5 (docs/meiling-soft-design.md): the Mac does what the Tab5 firmware does.
///   dictation  talk key → Mac mic → transcribe-live → each confirmed sentence through the 美玲 input method
///   meeting    talk key → Mac mic → live-translate en → virtual mic (BlackHole); the meeting app's sound →
///              live-translate zh-Hans → private caption window; my side → the shared caption window
/// The Tab5 key-frame path (MeilingCoordinator) is untouched and can run alongside.
@MainActor
final class MeilingSoftController {
    static let shared = MeilingSoftController()
    static let enabledKey = "meilingSoftEnabled"
    static let micKey = "meilingSoftMic", virtualMicKey = "meilingSoftVirtualMic"
    static let allowSpeakerKey = "meilingSoftAllowSpeaker"
    static let monitorKey = "meilingSoftMonitor"  // 耳返, on unless turned off
    static var monitorOn: Bool { UserDefaults.standard.object(forKey: monitorKey) as? Bool ?? true }
    static let inputMonitoringHint = "Talk key needs Input Monitoring: allow AISM in Privacy & Security → Input Monitoring (remove and re-add it after a rebuild), then reopen AISM"

    private let hotkey = MeilingSoftHotkey()
    private let committer = MeilingSoftCommitter()
    private let log = MeilingLog()
    private var dictation: MeilingDictationEngine?
    private var meeting: MeilingMeetingEngine?
    private var dictationKey = ""
    private(set) var lastError: String?
    private(set) var meetingStarting = false
    /// Bumped by every cancel, disable, meeting start and meeting stop: a meeting start that lands in an older
    /// epoch is abandoned. (Dictation finals are matched to their session instead, see makeDictation.)
    private var epoch = 0
    private var vocabularyDirty = false

    var enabled: Bool { hotkey.running }
    var meetingActive: Bool { meeting != nil }
    var passthrough: Bool { meeting?.passthrough ?? false }

    // MARK: settings files (~/Library/Application Support/AISM)

    static var supportDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AISM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// GEMINI_API_KEY=... in a 0600 file, like luna-work's .env (an ad-hoc signed app would hit a Keychain prompt
    /// after every rebuild).
    static var keyFile: URL { supportDir.appendingPathComponent("meiling.env") }
    static var termsFile: URL { supportDir.appendingPathComponent("meiling-terms.json") }

    static func apiKey() -> String? {
        guard let text = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("GEMINI_API_KEY=") {
            let key = line.dropFirst("GEMINI_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            return key.isEmpty ? nil : key
        }
        return nil
    }

    static func saveAPIKey(_ key: String) throws {
        try Data("GEMINI_API_KEY=\(key)\n".utf8).write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    /// Google: up to 1000 terms, best results with about 100 (the server refused 1200 on 2026-10-25, and 699 hurt
    /// recognition that evening). The owner chose ~150: corrected words first, then the list (sorted by importance).
    static let maxVocabulary = 150

    /// Learned corrections first, then terms.json (a plain string array, or [{"term": …}]).
    static func vocabulary() -> [String] {
        let data = try? Data(contentsOf: termsFile)
        let terms = data.flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) }?.compactMap { $0["term"] }
            ?? data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return MeilingCorrections.vocabulary(MeilingCorrectionStore.shared.corrections, terms: terms, limit: maxVocabulary)
    }

    /// A new correction or list: the next press opens a session with the new vocabulary (it is fixed at setup).
    func vocabularyChanged() {
        guard let dictation else { return }
        guard !dictation.talking else {
            vocabularyDirty = true  // rebuilt on the next press (review C4)
            return
        }
        dictation.shutdown()
        self.dictation = nil
    }

    // MARK: on / off

    func enable() {
        lastError = nil
        hotkey.onEdge = { [weak self] edge in self?.talk(edge) }
        // Without Input Monitoring the tap may still be created but sees no keys. AISM is ad-hoc signed, so every
        // rebuild loses the grant and must be allowed again.
        let listen = CGPreflightListenEventAccess()
        guard listen, hotkey.start() else {
            if !listen { CGRequestListenEventAccess() }
            lastError = Self.inputMonitoringHint
            MeilingSoftHUD.shared.error(Self.inputMonitoringHint)
            log.write("soft: hotkey tap refused (listen access \(listen))")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard !granted else { return }
            Task { @MainActor in
                MeilingSoftController.shared.lastError = "No microphone access: allow AISM in Privacy & Security → Microphone"
            }
        }
        log.write("soft: enabled key=\(MeilingSoftHotkey.current.name)")
    }

    func disable() {
        epoch += 1
        committer.cancelPending()
        hotkey.stop()
        dictation?.shutdown()
        dictation = nil
        stopMeeting()
        MeilingSoftHUD.shared.stopped()
        log.write("soft: disabled")
    }

    // MARK: talk key

    private func talk(_ edge: MeilingTalkEdge) {
        log.write("soft: talk key \(edge)")
        switch edge {
        case .start: NSSound(named: "Tink")?.play()
        case .stop: NSSound(named: "Pop")?.play()
        case .cancel, .none: break
        }
        // While the meeting starts (the System Audio Recording prompt can hold it for long), edges are ignored:
        // routed to dictation they opened a mic that the meeting never closed (review C1).
        if meetingStarting {
            hotkey.reset()
            if edge == .start { MeilingSoftHUD.shared.error("Meeting interpretation is starting: wait a moment") }
            return
        }
        if let meeting {
            switch edge {
            case .start:
                guard !meeting.passthrough else {
                    MeilingSoftHUD.shared.error("Passthrough is on: the talk key does nothing (turn off Passthrough in Settings → Meyrin)")
                    hotkey.reset()
                    return
                }
                meeting.startTalk()
                MeilingSoftHUD.shared.listening("Interpreting → English · release to stop")
                MeilingSoftHUD.shared.mic(meeting.mic.deviceName)
            case .stop, .cancel:
                meeting.stopTalk()  // a cancelled press still flushes: what was said is already on its way
                MeilingSoftHUD.shared.stopped()
            case .none:
                break
            }
            return
        }
        switch edge {
        case .start: startDictation()
        case .stop:
            dictation?.end()
            MeilingSoftHUD.shared.stopped()
        case .cancel:
            dictation?.cancel()
            committer.cancelPending()
            MeilingSoftHUD.shared.interim("")
            MeilingSoftHUD.shared.stopped()
            log.write("soft: dictation cancelled (chord or Esc)")
        case .none:
            break
        }
    }

    private func startDictation() {
        guard MeilingInputSwitcher.installed else {
            hotkey.reset()
            MeilingSoftHUD.shared.error("Meyrin input method not installed or not enabled: Settings → Meyrin → Install")
            return
        }
        guard let key = Self.apiKey() else {
            hotkey.reset()
            MeilingSoftHUD.shared.error("No Gemini API key: Settings → Meyrin → Gemini API Key")
            return
        }
        if dictation == nil || dictationKey != key || vocabularyDirty {
            vocabularyDirty = false
            dictation?.shutdown()
            dictation = makeDictation(key)
            dictationKey = key
        }
        MeilingSoftHUD.shared.listening("Meyrin Dictation · \(MeilingSoftHotkey.current.name)")
        dictation?.begin(micName: UserDefaults.standard.string(forKey: Self.micKey) ?? "")
        if let mic = dictation?.mic, mic.running { MeilingSoftHUD.shared.mic(mic.deviceName) }
    }

    private func makeDictation(_ key: String) -> MeilingDictationEngine {
        let engine = MeilingDictationEngine(apiKey: key, vocabulary: Self.vocabulary())
        engine.mic.onLevel = { level in Task { @MainActor in MeilingSoftHUD.shared.level(level) } }
        engine.onInterim = { [weak self] text in
            Task { @MainActor in
                guard let self, self.dictation === engine, self.dictation?.talking == true else { return }
                MeilingSoftHUD.shared.interim(text)
            }
        }
        engine.onFinal = { [weak self] text, session in
            Task { @MainActor in
                // A cancelled talk's session is gone (cancel sets it to nil): its in-flight finals stop here.
                guard let self, self.dictation === engine, engine.currentSession == session else {
                    MeilingDictationHistory.shared.add(text, source: "Mac", status: .cancelled)
                    self?.log.write("soft: final dropped (talk cancelled)")
                    return
                }
                self.deliver(text)
            }
        }
        engine.onTalkSummary = { [weak self] line in Task { @MainActor in self?.log.write("soft: dictation \(line)") } }
        engine.onError = { [weak self] text in
            Task { @MainActor in
                self?.hotkey.reset()
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

    private func deliver(_ heard: String) {
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

    // MARK: meeting

    func startMeeting() {
        guard meeting == nil, !meetingStarting else { return }
        guard let key = Self.apiKey() else {
            lastError = "No Gemini API key"
            MeilingSoftHUD.shared.error("No Gemini API key: Settings → Meyrin → Gemini API Key")
            return
        }
        if MeilingAudioDevices.defaultOutputIsBuiltInSpeaker(), !UserDefaults.standard.bool(forKey: Self.allowSpeakerKey) {
            MeilingSoftHUD.shared.error("Use headphones: on speakers the mic picks up the other side and translates it back")
            return
        }
        meetingStarting = true
        epoch += 1
        let startEpoch = epoch
        committer.cancelPending()
        dictation?.cancel()
        hotkey.reset()
        let engine = MeilingMeetingEngine(apiKey: key)
        engine.mic.onLevel = { level in Task { @MainActor in MeilingSoftHUD.shared.level(level) } }
        // Lines flushed after the meeting stopped are dropped: the windows are closed by then.
        engine.onCaption = { [weak self] caption in
            Task { @MainActor in
                guard self?.meeting === engine else { return }
                let window = caption.mine ? MeilingSoftCaptionWindow.mine : MeilingSoftCaptionWindow.theirs
                window.append(text: caption.text, original: caption.original)
            }
        }
        engine.onPending = { [weak self] caption in
            Task { @MainActor in
                guard self?.meeting === engine else { return }
                let window = caption.mine ? MeilingSoftCaptionWindow.mine : MeilingSoftCaptionWindow.theirs
                window.setPending(text: caption.text, original: caption.original)
            }
        }
        engine.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.log.write("soft: meeting \(status)")
                if status.hasPrefix("WARN: ") { MeilingSoftHUD.shared.error(String(status.dropFirst(6))) }
            }
        }
        let mic = UserDefaults.standard.string(forKey: Self.micKey) ?? ""
        let vmic = UserDefaults.standard.string(forKey: Self.virtualMicKey) ?? MeilingVirtualMic.defaultDeviceName
        // Off the main thread: AudioDeviceStart on the tap waits for the "System Audio Recording" prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try engine.start(micName: mic, virtualMicName: vmic, monitor: Self.monitorOn)
                Task { @MainActor in
                    self.meetingStarting = false
                    guard self.epoch == startEpoch, self.enabled else {  // stopped or disabled while starting
                        DispatchQueue.global(qos: .userInitiated).async { engine.stop() }
                        self.log.write("soft: meeting start abandoned")
                        return
                    }
                    self.meeting = engine
                    self.hotkey.holdOnly = true
                    self.lastError = nil
                    MeilingSoftCaptionWindow.mine.show()
                    MeilingSoftCaptionWindow.theirs.show()
                    self.log.write("soft: meeting started vmic=\(engine.virtualMic.deviceName) mic=\(engine.mic.deviceName) monitor=\(engine.monitoring ? engine.monitor.deviceName : "off")")
                    MeilingSoftHUD.shared.error("Meeting interpretation on: pick \"\(engine.virtualMic.micNameForApps)\" as the microphone in your meeting app; hold \(MeilingSoftHotkey.current.name) while you talk")
                    self.checkTapSoon(engine)
                }
            } catch {
                Task { @MainActor in
                    self.meetingStarting = false
                    self.lastError = "\(error)"
                    MeilingSoftHUD.shared.error("Meeting interpretation did not start: \(error)")
                    self.log.write("soft: meeting start failed \(error)")
                }
            }
        }
    }

    /// The tap delivers silence when System Audio Recording is denied: say so once nothing arrived for 20 s.
    private func checkTapSoon(_ engine: MeilingMeetingEngine) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.meeting === engine, engine.tap.peak == 0 else { return }
            MeilingSoftHUD.shared.error("No meeting audio for 20 s: check the meeting is playing sound and AISM is allowed in Screen & System Audio Recording")
        }
    }

    func stopMeeting() {
        if meetingStarting { epoch += 1 }  // the start in flight is abandoned when it lands
        guard let engine = meeting else { return }
        meeting = nil
        hotkey.reset()
        hotkey.holdOnly = false
        MeilingSoftHUD.shared.stopped()
        MeilingSoftCaptionWindow.mine.hide()
        MeilingSoftCaptionWindow.theirs.hide()
        DispatchQueue.global(qos: .userInitiated).async { engine.stop() }
        log.write("soft: meeting stopped")
    }

    /// 耳返 on or off, now and for later meetings.
    func setMonitor(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.monitorKey)
        guard let engine = meeting else { return }
        DispatchQueue.global(qos: .userInitiated).async { engine.setMonitor(on) }
        log.write("soft: monitor \(on)")
    }

    func togglePassthrough() {
        guard let meeting else { return }
        meeting.setPassthrough(!meeting.passthrough)
        hotkey.reset()
        if meeting.passthrough {
            MeilingSoftHUD.shared.listening("Passthrough: your own voice goes to the meeting")
            MeilingSoftHUD.shared.mic(meeting.mic.deviceName)
        } else {
            MeilingSoftHUD.shared.stopped()
        }
        log.write("soft: passthrough \(meeting.passthrough)")
    }
}
