import Foundation

/// Luna's spoken notification lines, the X10A Tab5's voice pack (luna-work tools/luna_voice, Gemini TTS "Leda"):
/// the same rules as the Tab5's Buddy cues (luna-work app/notify/buddy_link.h), so AISM can speak them itself.
///   red    a permission request, or a turn that failed
///   blue   a turn finished (a second blue within `blueDedupe` is the same finish)
///   boot   AISM starts
/// Starting work and submitting a prompt stay silent, as on the Tab5 (its green cue was dropped in 0.7.70).
public struct LunaLine: Codable, Equatable, Sendable {
    public let id: String
    public let group: String
    public let ja: String
    public let zh: String
    public let event: String

    public init(id: String, group: String, ja: String, zh: String, event: String = "") {
        self.id = id
        self.group = group
        self.ja = ja
        self.zh = zh
        self.event = event
    }
}

public enum LunaVoiceRules {
    public static let red = "red", blue = "blue", boot = "boot"
    public static let blueDedupe: TimeInterval = 2

    /// The voice group for an AISM sound event, or nil for one Luna does not speak.
    public static func group(forEvent event: String) -> String? {
        switch event {
        case "PermissionRequest", EventSoundRouting.turnFailed: return red
        case "Stop", "TaskRoundComplete": return blue
        default: return nil
        }
    }
}

/// Which line to speak, and when: a random line of the group that is not the one just spoken (when there is a
/// choice); one line at a time, the next cues waiting their turn (at most `maxQueued`); blue de-duplicated.
public struct LunaVoiceQueue: Sendable {
    public static let maxQueued = 3

    public private(set) var queued: [String] = []
    private var lastLineId: String?
    private var lastBlue: Date?

    public init() {}

    /// A cue arrived. False when it is dropped (a repeated blue, or the queue is full).
    public mutating func push(_ group: String, now: Date) -> Bool {
        if group == LunaVoiceRules.blue {
            if let lastBlue, now.timeIntervalSince(lastBlue) < LunaVoiceRules.blueDedupe { return false }
            lastBlue = now
        }
        guard queued.count < Self.maxQueued else { return false }
        queued.append(group)
        return true
    }

    /// The next line to play from `lines`, or nil when nothing is queued (a group without lines is skipped).
    public mutating func next(from lines: [LunaLine], random: (Int) -> Int) -> LunaLine? {
        while !queued.isEmpty {
            let group = queued.removeFirst()
            var pick = lines.filter { $0.group == group }
            if pick.count > 1 { pick.removeAll { $0.id == lastLineId } }
            guard !pick.isEmpty else { continue }
            let line = pick[random(pick.count)]
            lastLineId = line.id
            return line
        }
        return nil
    }
}
