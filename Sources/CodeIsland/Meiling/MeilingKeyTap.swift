import AppKit
import CoreGraphics

/// Sees every key event before any input method (a session-level CGEvent tap) and hands key-downs to the
/// coordinator, which says which to swallow. Keys we re-post ourselves carry `repostMarker` and pass untouched.
final class MeilingKeyTap {
    static let repostMarker: Int64 = 0x4D4C_5245  // "MLRE"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedDown = Set<UInt16>()
    private let onKeyDown: (UInt16, UInt64) -> Bool

    /// `onKeyDown(keyCode, nowMs)` returns whether to swallow the key (its key-up is then swallowed too).
    init(onKeyDown: @escaping (UInt16, UInt64) -> Bool) {
        self.onKeyDown = onKeyDown
    }

    var running: Bool { tap != nil }

    /// Needs Input Monitoring (and Accessibility to post). Returns false when macOS refuses the tap.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MeilingKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowedDown.removeAll()
    }

    /// Re-posts keys the assembler held back (a lone marker), down and up, marked so we let them through.
    static func repost(_ keyCodes: [UInt16]) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyCode in keyCodes {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: repostMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.repostMarker { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedDown.remove(keyCode) != nil ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return swallowedDown.contains(keyCode) ? nil : Unmanaged.passUnretained(event)
        }
        let nowMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        if onKeyDown(keyCode, nowMs) {
            swallowedDown.insert(keyCode)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
