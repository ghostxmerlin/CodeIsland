import AppKit
import CodeIslandCore
import CoreGraphics

/// A Mac talk key for the software mode: one lone modifier, fn or an F-key, recorded in Settings → Meyrin. There
/// are two, each with its own tap: the talk key (right ⌘ by default) dictates as said, the translate key (right ⌥)
/// dictates into English. Other keys are refused: the tap only listens, so a letter key would also type. Tap =
/// latch, hold ≥ 300 ms = push-to-talk (hold only during a meeting); another key while it is down (⌘C …) makes it
/// a shortcut and cancels; Esc while talking cancels. No event is ever swallowed or delayed.
@MainActor
final class MeilingSoftHotkey {
    struct Key {
        let keyCode: Int64
        let name: String
        let deviceMask: UInt64  // the side-specific NX_DEVICE*KEYMASK bit, or 0 for fn and F-keys
        var isModifier: Bool { keyCode == 63 || deviceMask != 0 }  // reported as flagsChanged, not keyDown / keyUp
    }

    static let keys: [Key] = [
        Key(keyCode: 54, name: "Right ⌘", deviceMask: 0x10),
        Key(keyCode: 61, name: "Right ⌥", deviceMask: 0x40),
        Key(keyCode: 62, name: "Right ⌃", deviceMask: 0x2000),
        Key(keyCode: 60, name: "Right ⇧", deviceMask: 0x04),
        Key(keyCode: 55, name: "Left ⌘", deviceMask: 0x08),
        Key(keyCode: 58, name: "Left ⌥", deviceMask: 0x20),
        Key(keyCode: 59, name: "Left ⌃", deviceMask: 0x01),
        Key(keyCode: 56, name: "Left ⇧", deviceMask: 0x02),
        Key(keyCode: 63, name: "fn", deviceMask: 0),
    ] + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].enumerated().map {
        Key(keyCode: Int64($0.element), name: "F\($0.offset + 1)", deviceMask: 0)
    }
    enum Slot: CaseIterable {
        case talk       // dictation as said
        case translate  // dictation into English (MeilingTranslate)

        var defaultsKey: String { self == .talk ? "meilingSoftTalkKey" : "meilingSoftTranslateKey" }
        var other: Slot { self == .talk ? .translate : .talk }
        var label: String { self == .talk ? "Talk Key" : "Translate Key" }
    }

    static let keyDefault = Slot.talk.defaultsKey
    /// True while Settings records a new key: the key being pressed must not start a dictation.
    static var paused = false

    static var current: Key { key(.talk) }

    /// The recorded key, else the default: right ⌘ to talk, right ⌥ to translate. The two never resolve to the same
    /// key (Settings refuses it; a translate key left at its default steps aside when the talk key takes right ⌥).
    static func key(_ slot: Slot, defaults: UserDefaults = .standard) -> Key {
        let stored = (defaults.object(forKey: slot.defaultsKey) as? Int).flatMap { code in
            keys.first { $0.keyCode == Int64(code) }
        }
        switch slot {
        case .talk:
            return stored ?? keys[0]
        case .translate:
            let talk = key(.talk, defaults: defaults)
            if let stored, stored.keyCode != talk.keyCode { return stored }
            let rightOption = keys[1], rightCommand = keys[0]
            return talk.keyCode == rightOption.keyCode ? rightCommand : rightOption
        }
    }

    let slot: Slot
    var key: Key { Self.key(slot) }

    init(slot: Slot = .talk) {
        self.slot = slot
    }

    var onEdge: ((MeilingTalkEdge) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = MeilingTalkGesture()
    private var down = false
    var running: Bool { tap != nil }
    var talking: Bool { gesture.talking }
    /// Meeting interpretation: talk only while the key is held (no tap latch).
    var holdOnly: Bool {
        get { gesture.holdOnly }
        set { gesture.holdOnly = newValue }
    }

    /// Needs Input Monitoring. False when macOS refuses the tap.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MeilingSoftHotkey>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        gesture.cancel()
        down = false
    }

    /// The talk ended elsewhere (error, menu): forget the latch.
    func reset() {
        gesture.cancel()
        down = false
    }

    private static func nowMs() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // The key may have gone up while we were blind: a push-to-talk must not keep running.
            let key = self.key
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let held = !key.isModifier ? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
                : key.deviceMask == 0 ? flags.contains(.maskSecondaryFn) : flags.rawValue & key.deviceMask != 0
            if down, !held {
                down = false
                emit(gesture.up(atMs: Self.nowMs()))
            }
            return
        }
        if Self.paused {
            if gesture.talking {
                gesture.cancel()
                emit(.cancel)
            }
            down = false
            return
        }
        let key = self.key
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if !key.isModifier, code == key.keyCode, type == .keyDown || type == .keyUp {  // an F-key
            if type == .keyDown, !down, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                down = true
                emit(gesture.down(atMs: Self.nowMs()))
            } else if type == .keyUp, down {
                down = false
                emit(gesture.up(atMs: Self.nowMs()))
            }
            return
        }
        switch type {
        case .flagsChanged:
            let flags = event.flags.rawValue
            let pressed = key.deviceMask == 0 ? event.flags.contains(.maskSecondaryFn) : flags & key.deviceMask != 0
            if key.isModifier, code == key.keyCode {
                if pressed, !down {
                    down = true
                    emit(gesture.down(atMs: Self.nowMs()))
                } else if !pressed, down {
                    down = false
                    emit(gesture.up(atMs: Self.nowMs()))
                }
            } else if down {
                emit(gesture.chord())  // another modifier with the talk key: a shortcut such as ⌘⇧4
            }
        case .keyDown:
            if code == 53, gesture.talking {  // Esc
                gesture.cancel()
                down = false
                emit(.cancel)
            } else if down {
                emit(gesture.chord())
            }
        default:
            break
        }
    }

    private func emit(_ edge: MeilingTalkEdge) {
        guard edge != .none else { return }
        onEdge?(edge)
    }
}
