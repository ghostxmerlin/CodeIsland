import Foundation

/// 美玲 talk key (luna-work app/meiling/press_gesture.*): a tap (released before 300 ms) latches talking until the
/// next tap; a hold of 300 ms or more is push-to-talk and stops on release. On the Mac the key is a lone modifier,
/// so a chord (another key while it is down, e.g. ⌘C) cancels the talk instead. `holdOnly` (meeting
/// interpretation) drops the latch: the mic is open only while the key is held, so one stray tap never leaves it
/// translating the room for minutes (2026-10-25).
public enum MeilingTalkEdge: Equatable, Sendable { case none, start, stop, cancel }

public struct MeilingTalkGesture: Sendable {
    public static let holdMs: UInt64 = 300

    public private(set) var talking = false
    public var holdOnly = false
    private var latched = false, pressed = false, chorded = false
    private var downMs: UInt64 = 0

    public init() {}

    public mutating func down(atMs now: UInt64) -> MeilingTalkEdge {
        guard !pressed else { return .none }
        pressed = true
        chorded = false
        downMs = now
        if talking { return .none }
        talking = true
        latched = false
        return .start
    }

    public mutating func up(atMs now: UInt64) -> MeilingTalkEdge {
        guard pressed else { return .none }
        pressed = false
        guard talking else { return .none }
        if chorded {
            if latched { return .none }  // a shortcut while latched: keep talking
            talking = false
            return .none  // the cancel was already reported
        }
        if latched || holdOnly || now - downMs >= Self.holdMs {
            talking = false
            latched = false
            return .stop
        }
        latched = true
        return .none
    }

    /// Another key went down while the talk key was held: it was a shortcut, not a talk press.
    public mutating func chord() -> MeilingTalkEdge {
        guard pressed, !chorded else { return .none }
        chorded = true
        if latched { return .none }  // the user is typing a shortcut while latched; keep talking
        talking = false
        return .cancel
    }

    public mutating func cancel() {
        talking = false
        latched = false
        pressed = false
        chorded = false
    }
}
