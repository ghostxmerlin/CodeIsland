import CodeIslandCore
import Foundation

/// The owner's learned corrections (History → Edit), kept in ~/Library/Application Support/AISM/corrections.json
/// (owner-only). Every dictated sentence, Mac or Tab5, passes `apply` before it is typed; the corrected words lead
/// the vocabulary (MeilingSoftController.vocabulary).
@MainActor
final class MeilingCorrectionStore: ObservableObject {
    static let shared = MeilingCorrectionStore()

    @Published private(set) var corrections: [MeilingCorrection]
    private let url = MeilingSoftController.supportDir.appendingPathComponent("corrections.json")
    private let log = MeilingLog()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        corrections = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([MeilingCorrection].self, from: $0) } ?? []
    }

    func apply(_ text: String) -> String { MeilingCorrections.apply(corrections, to: text) }

    /// Learns the misheard words between a sentence and its correction; returns the pairs it found.
    func learn(heard: String, corrected: String) -> [MeilingCorrection] {
        let found = MeilingCorrections.pairs(heard: heard, corrected: corrected)
        guard !found.isEmpty else { return [] }
        MeilingCorrections.learn(found, into: &corrections)
        save()
        log.write("corrections: learned \(found.count), \(corrections.count) in all")
        MeilingSoftController.shared.vocabularyChanged()
        return corrections.filter { c in found.contains { $0.heard == c.heard && $0.right == c.right } }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = corrections.firstIndex(where: { $0.id == id }) else { return }
        corrections[i].enabled = on
        save()
        MeilingSoftController.shared.vocabularyChanged()
    }

    func remove(_ id: String) {
        corrections.removeAll { $0.id == id }
        save()
        MeilingSoftController.shared.vocabularyChanged()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(corrections).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.write("corrections: save failed \(error.localizedDescription)")
        }
    }
}
