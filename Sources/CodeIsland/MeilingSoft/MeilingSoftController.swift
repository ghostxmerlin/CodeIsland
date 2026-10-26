import AppKit
import AVFoundation
import CodeIslandCore
import MeilingSoftKit

/// The software mode (docs/meiling-soft-design.md): the Mac does what the Tab5 firmware does, without the Tab5.
/// Turns the mode on and off, owns the talk key, and gives each edge to the meeting when one is on (or starting)
/// and to dictation otherwise. The work itself is in MeilingSoftDictation and MeilingSoftMeeting; settings and files
/// in MeilingSoftSettings. The Tab5 hardware mode (MeilingCoordinator) is separate.
@MainActor
final class MeilingSoftController {
    static let shared = MeilingSoftController()
    static let inputMonitoringHint = "Talk key needs Input Monitoring: allow AISM in Privacy & Security → Input Monitoring (remove and re-add it after a rebuild), then reopen AISM"

    let dictation = MeilingSoftDictation()
    let meeting = MeilingSoftMeeting()
    private let hotkey = MeilingSoftHotkey()
    private let log = MeilingLog()
    private var enableError: String?

    var enabled: Bool { hotkey.running }
    var lastError: String? { enableError ?? meeting.lastError }

    private init() {
        hotkey.onEdge = { [weak self] edge in self?.talk(edge) }
        dictation.onTalkEnded = { [weak self] in self?.hotkey.reset() }
        meeting.onStateChange = { [weak self] state in
            guard let self else { return }
            self.hotkey.reset()
            if case .on = state { self.hotkey.holdOnly = true } else { self.hotkey.holdOnly = false }
        }
        MeilingCorrectionStore.shared.onChange = { [weak self] in self?.dictation.vocabularyChanged() }
    }

    // MARK: on / off (the choice is remembered here, the one place that writes it)

    func enable() {
        enableError = nil
        // Without Input Monitoring the tap may still be created but sees no keys.
        let listen = CGPreflightListenEventAccess()
        guard listen, hotkey.start() else {
            if !listen { CGRequestListenEventAccess() }
            enableError = Self.inputMonitoringHint
            MeilingSoftHUD.shared.error(Self.inputMonitoringHint)
            log.write("soft: hotkey tap refused (listen access \(listen))")
            UserDefaults.standard.set(false, forKey: MeilingSoftSettings.enabledKey)
            return
        }
        UserDefaults.standard.set(true, forKey: MeilingSoftSettings.enabledKey)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard !granted else { return }
            Task { @MainActor in
                MeilingSoftController.shared.enableError = "No microphone access: allow AISM in Privacy & Security → Microphone"
            }
        }
        log.write("soft: enabled key=\(MeilingSoftHotkey.current.name)")
    }

    func disable() {
        hotkey.stop()
        dictation.shutdown()
        meeting.stop()
        MeilingSoftHUD.shared.stopped()
        UserDefaults.standard.set(false, forKey: MeilingSoftSettings.enabledKey)
        log.write("soft: disabled")
    }

    // MARK: meeting

    func startMeeting() {
        dictation.shutdown()  // the meeting takes the mic and the talk key
        meeting.start()
    }

    func stopMeeting() { meeting.stop() }

    // MARK: talk key

    private func talk(_ edge: MeilingTalkEdge) {
        log.write("soft: talk key \(edge)")
        switch edge {
        case .start: NSSound(named: "Tink")?.play()
        case .stop: NSSound(named: "Pop")?.play()
        case .cancel, .none: break
        }
        switch meeting.state {
        case .starting:
            // The System Audio Recording prompt can hold the start for long: an edge routed to dictation would
            // open a mic the meeting never closes (review C1).
            hotkey.reset()
            if edge == .start { MeilingSoftHUD.shared.notice("Meeting interpretation is starting: wait a moment") }
        case .on:
            switch edge {
            case .start:
                if meeting.passthrough { hotkey.reset() }
                meeting.startTalk()
            case .stop, .cancel: meeting.stopTalk()
            case .none: break
            }
        case .off:
            switch edge {
            case .start: if !dictation.start() { hotkey.reset() }
            case .stop: dictation.stop()
            case .cancel: dictation.cancel()
            case .none: break
            }
        }
    }
}
