import Foundation

/// aism ⇄ the Meyrin input method over local CFMessagePorts (no distributed notifications: dictated text stays
/// private). One definition for both sides (the app and the input method bundle).
///   aism → IME  `imePort`  msgid `commit`    = UTF-8 text; reply `ok` or `inactive` (insert now, into the active client)
///   aism → IME  `imePort`  msgid `prepare`   = UTF-8 text; reply `ok` (insert it on the next activation)
///   aism → IME  `imePort`  msgid `cancel`    = empty; reply `pending` (it was still waiting: dropped) or `none`
///                                             (nothing waits: it was inserted, or never prepared)
///   IME → aism  `appPort`  msgid `activated` = the client's bundle id
///   IME → aism  `appPort`  msgid `committed` = the client's bundle id (a prepared text went in on activation)
/// Why prepare (2026-10-29): after a programmatic switch iTerm2 / Lark drop the input method about 2 ms after
/// activating it, so a commit sent after the "activated" message often found no client. Inserting inside
/// activateServer has no such race.
public enum MeilingIPC {
    public static let imePort = "com.aism.meiling.ime", appPort = "com.aism.meiling.app"
    public static let commit: Int32 = 1, activated: Int32 = 2, prepare: Int32 = 3, cancel: Int32 = 4,
                      committed: Int32 = 5
    public static let ok = "ok", inactive = "inactive", pending = "pending", none = "none"
}

/// The input method's one waiting sentence: set by `prepare`, taken by the next activation, dropped by `cancel` or
/// when older than `maxAge` (a switch that never activated must not type it minutes later).
public struct MeilingPendingText {
    public static let maxAge: TimeInterval = 3
    private var text: String?
    private var since = Date.distantPast

    public init() {}

    public mutating func set(_ text: String, now: Date = Date()) {
        self.text = text
        since = now
    }

    /// The waiting text if it is fresh; either way nothing waits afterwards.
    public mutating func take(now: Date = Date()) -> String? {
        defer { text = nil }
        guard let text, now.timeIntervalSince(since) <= Self.maxAge else { return nil }
        return text
    }

    /// True when a text was still waiting (now dropped).
    @discardableResult
    public mutating func clear() -> Bool {
        defer { text = nil }
        return text != nil
    }
}
