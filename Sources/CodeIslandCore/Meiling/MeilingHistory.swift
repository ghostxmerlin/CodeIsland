import Foundation

/// One dictated sentence in the Meyrin history, kept so a sentence that never reached the cursor can be copied
/// instead of said again. Recorded when the final sentence arrives (`pending`), then marked with the outcome.
public struct MeilingHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending    // the final arrived, the commit has not answered yet (or the app quit meanwhile)
        case typed      // committed at the cursor
        case notTyped   // the commit failed: `note` says why
        case cancelled  // the talk was cancelled (Esc or a shortcut) after this sentence was heard
    }

    public let id: UUID
    public let date: Date
    public let text: String
    public let source: String  // "Mac" or "Tab5"
    public var status: Status
    public var note: String?
    /// The owner's correction of `text` (History → Edit); the corrected words are learned (MeilingCorrections).
    public var corrected: String?

    public init(id: UUID = UUID(), date: Date = Date(), text: String, source: String, status: Status = .pending,
                note: String? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.source = source
        self.status = status
        self.note = note
    }
}

/// The history file: one JSON object per line, oldest first, at most `maxEntries`. Rewritten atomically on each
/// change (a few hundred KB at most) and readable only by the owner: it holds dictated text, which the
/// Meyrin log never does.
public struct MeilingHistoryFile: Sendable {
    public static let defaultMaxEntries = 1000

    public let url: URL
    public let maxEntries: Int

    public init(url: URL, maxEntries: Int = defaultMaxEntries) {
        self.url = url
        self.maxEntries = maxEntries
    }

    /// Unreadable lines are skipped, so one bad write never loses the rest.
    public func load() -> [MeilingHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder()
        let entries = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(MeilingHistoryEntry.self, from: Data($0))
        }
        return Array(entries.suffix(maxEntries))
    }

    public func save(_ entries: [MeilingHistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries.suffix(maxEntries) {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
