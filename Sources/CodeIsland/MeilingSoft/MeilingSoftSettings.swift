import CodeIslandCore
import Foundation
import MeilingSoftKit

/// The software mode's settings: files in ~/Library/Application Support/AISM and the UserDefaults keys.
enum MeilingSoftSettings {
    static let enabledKey = "meilingSoftEnabled"
    static let micKey = "meilingSoftMic", virtualMicKey = "meilingSoftVirtualMic"
    static let allowSpeakerKey = "meilingSoftAllowSpeaker"
    static let monitorKey = "meilingSoftMonitor"  // 耳返, on unless turned off

    static var monitorOn: Bool { UserDefaults.standard.object(forKey: monitorKey) as? Bool ?? true }
    static var micName: String { UserDefaults.standard.string(forKey: micKey) ?? "" }
    static var virtualMicName: String { UserDefaults.standard.string(forKey: virtualMicKey) ?? MeilingVirtualMic.defaultDeviceName }
    static var allowSpeaker: Bool { UserDefaults.standard.bool(forKey: allowSpeakerKey) }

    static let supportDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AISM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// GEMINI_API_KEY=... in a 0600 file (an ad-hoc signed app would hit a Keychain prompt after every rebuild).
    static let keyFile = supportDir.appendingPathComponent("meiling.env")
    static let termsFile = supportDir.appendingPathComponent("meiling-terms.json")
    static let historyFile = supportDir.appendingPathComponent("dictation-history.jsonl")
    static let correctionsFile = supportDir.appendingPathComponent("corrections.json")

    static func apiKey() -> String? {
        (try? String(contentsOf: keyFile, encoding: .utf8)).flatMap(MeilingSoftFiles.apiKey(fromEnv:))
    }

    static func saveAPIKey(_ key: String) throws {
        try Data("GEMINI_API_KEY=\(key)\n".utf8).write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    /// Google: up to 1000 terms, best results with about 100 (the server refused 1200 on 2026-10-25, and 699 hurt
    /// recognition that evening). The owner chose ~150: corrected words first, then the list (sorted by importance).
    static let maxVocabulary = 150

    static func vocabulary(corrections: [MeilingCorrection]) -> [String] {
        let terms = (try? Data(contentsOf: termsFile)).map(MeilingSoftFiles.terms(from:)) ?? []
        return MeilingCorrections.vocabulary(corrections, terms: terms, limit: maxVocabulary)
    }
}
