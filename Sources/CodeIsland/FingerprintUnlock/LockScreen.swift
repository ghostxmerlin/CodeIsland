import AppKit
import ApplicationServices
import CoreGraphics
import Security

/// Why the password was not typed. Every case means nothing was typed past
/// that point.
enum LockScreenRefusal: Error, Equatable {
    case notLocked
    case notLoginWindow
    case signatureCheckFailed
    /// The display is off or loginwindow has no visible window yet.
    case noVisibleWindow
    case noAccessibility
    case invalidPassword
    case targetChanged
    case eventCreationFailed
}

/// Lock-screen detection and password entry, ported from exia's
/// `LockScreen` (Sources/main.swift) and verified there on macOS 26.
enum LockScreen {
    private static let loginWindowBundleId = "com.apple.loginwindow"
    private static let loginWindowPath = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
    private static let chunkUnits = 20
    private static let returnKey: CGKeyCode = 36

    /// `true` locked, `false` an unlocked console session, `nil` unknown —
    /// unknown must be treated as "don't unlock".
    static func state() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        for key in ["CGSSessionScreenIsLocked", "ScreenIsLocked"] {
            if let value = session[key] as? Bool { return value }
        }
        // These lock keys are absent in a normal unlocked console session.
        if session[kCGSessionOnConsoleKey as String] as? Bool == true,
           session[kCGSessionLoginDoneKey as String] as? Bool == true { return false }
        return nil
    }

    /// The pid of the Apple-signed loginwindow showing a visible lock
    /// screen, or a refusal.
    static func target() throws -> pid_t {
        guard state() == true else { throw LockScreenRefusal.notLocked }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == loginWindowBundleId,
              app.executableURL?.path == loginWindowPath else {
            throw LockScreenRefusal.notLoginWindow
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            throw LockScreenRefusal.signatureCheckFailed
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"com.apple.loginwindow\"" as CFString,
                                             [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw LockScreenRefusal.signatureCheckFailed
        }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              windows.contains(where: { item in
                  guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                        let bounds = item[kCGWindowBounds as String] as? [String: Any],
                        let width = bounds["Width"] as? Double,
                        let height = bounds["Height"] as? Double else { return false }
                  return width > 100 && height > 100
              }) else {
            throw LockScreenRefusal.noVisibleWindow
        }
        return app.processIdentifier
    }

    /// Type `password` into the lock screen and press Return, re-checking the
    /// target before every chunk and before Return. CGEvents follow focus, so
    /// the checks narrow focus races but cannot rule them out.
    static func enter(_ password: Data) throws {
        guard AXIsProcessTrusted() else { throw LockScreenRefusal.noAccessibility }
        let pid = try target()
        guard let text = String(data: password, encoding: .utf8), !text.isEmpty,
              !text.contains("\n"), !text.contains("\r") else { throw LockScreenRefusal.invalidPassword }
        var units = Array(text.utf16)
        defer { for index in units.indices { units[index] = 0 } }
        let source = CGEventSource(stateID: .hidSystemState)
        for offset in stride(from: 0, to: units.count, by: chunkUnits) {
            guard try target() == pid else { throw LockScreenRefusal.targetChanged }
            let count = min(chunkUnits, units.count - offset)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw LockScreenRefusal.eventCreationFailed
            }
            down.flags = []
            up.flags = []
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress! + offset)
                up.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress! + offset)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        guard try target() == pid else { throw LockScreenRefusal.targetChanged }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw LockScreenRefusal.eventCreationFailed
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
