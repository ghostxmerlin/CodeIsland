import Carbon
import Foundation

/// What the software-mode committer needs from the input-source switch (a fake in the tests).
protocol MeilingCommitSwitching: AnyObject {
    var meilingActive: Bool { get }
    func selectMeiling() -> Bool
    func selectOther()
    func restore()
}

/// Selects the 美玲 input method for one dictation frame and puts the user's own source back afterwards.
final class MeilingInputSwitcher: MeilingCommitSwitching {
    static let sourceID = "com.aism.inputmethod.Meiling.Meiling"
    private var remembered: TISInputSource?

    private static func source(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    static func currentID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static var installed: Bool { source(withID: sourceID) != nil }
    var meilingActive: Bool { Self.currentID() == Self.sourceID }

    /// False when the input method is not installed or not enabled in System Settings.
    @discardableResult
    func selectMeiling() -> Bool {
        guard let meiling = Self.source(withID: Self.sourceID) else { return false }
        if !meilingActive { remembered = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() }
        return TISSelectInputSource(meiling) == noErr
    }

    /// Leaves 美玲 for the remembered source (or ABC), keeping it remembered: the commit retry switches away and
    /// back so the focused client activates the input method again.
    func selectOther() {
        if let previous = remembered ?? Self.source(withID: "com.apple.keylayout.ABC") {
            if remembered == nil { remembered = previous }
            TISSelectInputSource(previous)
        }
    }

    func restore() {
        guard let previous = remembered else { return }
        remembered = nil
        TISSelectInputSource(previous)
    }
}
