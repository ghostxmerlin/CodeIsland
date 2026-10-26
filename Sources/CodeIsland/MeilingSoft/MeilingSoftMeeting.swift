import AppKit
import MeilingSoftKit

/// Software-mode meeting interpretation: my side (talk key) → English into the virtual mic, the meeting app's
/// sound → Chinese captions only I see. One state: off, starting (a start in flight, identified by a token, so a
/// stop or disable while it starts makes it abandon when it lands), or on.
@MainActor
final class MeilingSoftMeeting {
    enum State {
        case off
        case starting(token: Int)
        case on(MeilingMeetingEngine)
    }

    /// on → hold-only talk key; any change → the talk key's latch is released.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .off {
        didSet { onStateChange?(state) }
    }
    private(set) var lastError: String?
    private var nextToken = 0
    private let log = MeilingLog()

    var engine: MeilingMeetingEngine? {
        if case let .on(engine) = state { return engine }
        return nil
    }
    var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }
    var passthrough: Bool { engine?.passthrough ?? false }

    func start() {
        guard case .off = state else { return }
        guard let key = MeilingSoftSettings.apiKey() else {
            lastError = "No Gemini API key"
            MeilingSoftHUD.shared.error("No Gemini API key: Settings → Meyrin → Gemini API Key")
            return
        }
        if MeilingAudioDevices.defaultOutputIsBuiltInSpeaker(), !MeilingSoftSettings.allowSpeaker {
            MeilingSoftHUD.shared.error("Use headphones: on speakers the mic picks up the other side and translates it back")
            return
        }
        nextToken += 1
        let token = nextToken
        state = .starting(token: token)
        let engine = makeEngine(key)
        let mic = MeilingSoftSettings.micName, vmic = MeilingSoftSettings.virtualMicName
        let monitor = MeilingSoftSettings.monitorOn
        // Off the main thread: AudioDeviceStart on the tap waits for the "System Audio Recording" prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try engine.start(micName: mic, virtualMicName: vmic, monitor: monitor)
                Task { @MainActor in self.landed(engine, token: token) }
            } catch {
                Task { @MainActor in
                    guard case .starting(token) = self.state else { return }
                    self.state = .off
                    self.lastError = "\(error)"
                    MeilingSoftHUD.shared.error("Meeting interpretation did not start: \(error)")
                    self.log.write("soft: meeting start failed \(error)")
                }
            }
        }
    }

    private func landed(_ engine: MeilingMeetingEngine, token: Int) {
        guard case .starting(token) = state else {  // stopped or disabled while starting
            DispatchQueue.global(qos: .userInitiated).async { engine.stop() }
            log.write("soft: meeting start abandoned")
            return
        }
        state = .on(engine)
        lastError = nil
        MeilingSoftCaptionWindow.mine.show()
        MeilingSoftCaptionWindow.theirs.show()
        log.write("soft: meeting started vmic=\(engine.virtualMic.deviceName) mic=\(engine.mic.deviceName) monitor=\(engine.monitoring ? engine.monitor.deviceName : "off")")
        MeilingSoftHUD.shared.notice("Meeting interpretation on: pick \"\(engine.virtualMic.micNameForApps)\" as the microphone in your meeting app; hold \(MeilingSoftHotkey.current.name) while you talk")
        checkTapSoon(engine)
    }

    func stop() {
        switch state {
        case .off:
            return
        case .starting:
            state = .off  // the start in flight abandons itself when it lands
        case let .on(engine):
            state = .off
            MeilingSoftHUD.shared.stopped()
            MeilingSoftCaptionWindow.mine.hide()
            MeilingSoftCaptionWindow.theirs.hide()
            DispatchQueue.global(qos: .userInitiated).async { engine.stop() }
            log.write("soft: meeting stopped")
        }
    }

    // MARK: talk key (hold only)

    func startTalk() {
        guard let engine else { return }
        guard !engine.passthrough else {
            MeilingSoftHUD.shared.error("Passthrough is on: the talk key does nothing (turn off Passthrough in Settings → Meyrin)")
            return
        }
        engine.startTalk()
        MeilingSoftHUD.shared.listening("Interpreting → English · release to stop")
        MeilingSoftHUD.shared.mic(engine.mic.deviceName)
    }

    /// Release or cancel: what was said is already on its way, so it is flushed and translated either way.
    func stopTalk() {
        engine?.stopTalk()
        MeilingSoftHUD.shared.stopped()
    }

    func togglePassthrough() {
        guard let engine else { return }
        engine.setPassthrough(!engine.passthrough)
        if engine.passthrough {
            MeilingSoftHUD.shared.listening("Passthrough: your own voice goes to the meeting")
            MeilingSoftHUD.shared.mic(engine.mic.deviceName)
        } else {
            MeilingSoftHUD.shared.stopped()
        }
        onStateChange?(state)
        log.write("soft: passthrough \(engine.passthrough)")
    }

    /// 耳返 on or off, now and for later meetings.
    func setMonitor(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: MeilingSoftSettings.monitorKey)
        guard let engine else { return }
        DispatchQueue.global(qos: .userInitiated).async { engine.setMonitor(on) }
        log.write("soft: monitor \(on)")
    }

    // MARK: engine

    /// The engine's callbacks arrive on the main queue in order (its callbackQueue), hence assumeIsolated.
    private func makeEngine(_ key: String) -> MeilingMeetingEngine {
        let engine = MeilingMeetingEngine(apiKey: key)
        engine.mic.onLevel = { level in DispatchQueue.main.async { MainActor.assumeIsolated { MeilingSoftHUD.shared.level(level) } } }
        // Lines flushed after the meeting stopped are dropped: the windows are closed by then.
        engine.onCaption = { [weak self] caption in
            MainActor.assumeIsolated {
                guard self?.engine === engine else { return }
                let window = caption.mine ? MeilingSoftCaptionWindow.mine : MeilingSoftCaptionWindow.theirs
                window.append(text: caption.text, original: caption.original)
            }
        }
        engine.onPending = { [weak self] caption in
            MainActor.assumeIsolated {
                guard self?.engine === engine else { return }
                let window = caption.mine ? MeilingSoftCaptionWindow.mine : MeilingSoftCaptionWindow.theirs
                window.setPending(text: caption.text, original: caption.original)
            }
        }
        engine.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                self?.log.write("soft: meeting \(status)")
                if status.hasPrefix("WARN: ") { MeilingSoftHUD.shared.error(String(status.dropFirst(6))) }
            }
        }
        return engine
    }

    /// The tap delivers silence when System Audio Recording is denied: say so once nothing arrived for 20 s.
    private func checkTapSoon(_ engine: MeilingMeetingEngine) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.engine === engine, engine.tap.peak == 0 else { return }
            MeilingSoftHUD.shared.error("No meeting audio for 20 s: check the meeting is playing sound and AISM is allowed in Screen & System Audio Recording")
        }
    }
}
