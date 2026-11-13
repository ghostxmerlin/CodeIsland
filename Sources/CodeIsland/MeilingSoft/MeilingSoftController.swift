import AppKit
import AVFoundation
import CodeIslandCore
import MeilingSoftKit

/// The software mode (docs/meiling-soft-design.md): the Mac does what the Tab5 firmware does, without the Tab5.
/// Turns the mode on and off, owns the two keys, and gives each talk-key edge to the meeting when one is on (or
/// starting) and to dictation otherwise; the translate key dictates into English and rests during a meeting. The
/// work itself is in MeilingSoftDictation and MeilingSoftMeeting; settings and files in MeilingSoftSettings. The Tab5 hardware mode (MeilingCoordinator) is separate.
@MainActor
final class MeilingSoftController {
    static let shared = MeilingSoftController()
    static let inputMonitoringHint = "Talk key needs Input Monitoring: allow AISM in Privacy & Security → Input Monitoring (remove and re-add it after a rebuild), then reopen AISM"

    let dictation = MeilingSoftDictation()
    let meeting = MeilingSoftMeeting()
    private let hotkey = MeilingSoftHotkey(slot: .talk)
    private let translateKey = MeilingSoftHotkey(slot: .translate)
    /// The key whose dictation is running: the other one is ignored until it ends.
    private var talkingSlot: MeilingSoftHotkey.Slot?
    private let log = MeilingLog()
    private var enableError: String?

    var enabled: Bool { hotkey.running }
    var lastError: String? { enableError ?? meeting.lastError }

    private init() {
        hotkey.onEdge = { [weak self] edge in self?.talk(edge, .talk) }
        translateKey.onEdge = { [weak self] edge in self?.talk(edge, .translate) }
        dictation.onTalkEnded = { [weak self] in self?.resetKeys() }
        meeting.onStateChange = { [weak self] state in
            guard let self else { return }
            self.resetKeys()
            if case .on = state { self.hotkey.holdOnly = true } else { self.hotkey.holdOnly = false }
        }
        MeilingCorrectionStore.shared.onChange = { [weak self] in self?.dictation.vocabularyChanged() }
    }

    // MARK: on / off (the choice is remembered here, the one place that writes it)

    func enable() {
        enableError = nil
        // Without Input Monitoring the tap may still be created but sees no keys.
        let listen = CGPreflightListenEventAccess()
        guard listen, hotkey.start(), translateKey.start() else {
            hotkey.stop()
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
        log.write("soft: enabled key=\(MeilingSoftHotkey.current.name) translate=\(MeilingSoftHotkey.key(.translate).name)")
    }

    func disable() {
        hotkey.stop()
        translateKey.stop()
        talkingSlot = nil
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

    // MARK: talk keys

    private var meetingOff: Bool {
        if case .off = meeting.state { return true }
        return false
    }

    private func resetKeys() {
        hotkey.reset()
        translateKey.reset()
        talkingSlot = nil
    }

    private func talk(_ edge: MeilingTalkEdge, _ slot: MeilingSoftHotkey.Slot) {
        let key = slot == .talk ? hotkey : translateKey
        if let busy = talkingSlot, busy != slot {
            // The other key is dictating (e.g. right ⌘C while the translate key is latched): not a talk press.
            key.reset()
            log.write("soft: \(slot) key \(edge) ignored (\(busy) key talking)")
            return
        }
        if slot == .translate, !meetingOff {
            key.reset()
            if edge == .start { MeilingSoftHUD.shared.notice("Meeting interpretation is on: the Translate Key rests until it stops") }
            return
        }
        log.write(slot == .talk ? "soft: talk key \(edge)" : "soft: translate key \(edge)")
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
            case .start:
                talkingSlot = slot
                if !dictation.start(english: slot == .translate) {
                    key.reset()
                    talkingSlot = nil
                }
            case .stop:
                talkingSlot = nil
                dictation.stop()
            case .cancel:
                talkingSlot = nil
                dictation.cancel()
            case .none: break
            }
        }
    }
}
