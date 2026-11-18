import Foundation

/// The owner's vocabulary for transcription (meiling-terms.json), as edited in Settings → Meyrin → Vocabulary.
/// The order is the priority: only the first terms fit under the limit (MeilingCorrections.vocabulary), and a new
/// term goes to the front. Terms are told apart without regard to case, as the vocabulary does.
public struct MeilingTermList: Equatable {
    public private(set) var terms: [String]

    public init(_ terms: [String] = []) { self.terms = terms }

    private static func clean(_ term: String) -> String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func index(of term: String) -> Int? {
        terms.firstIndex { $0.lowercased() == term.lowercased() }
    }

    /// False when it is empty or already in the list.
    @discardableResult
    public mutating func add(_ term: String) -> Bool {
        let term = Self.clean(term)
        guard !term.isEmpty, index(of: term) == nil else { return false }
        terms.insert(term, at: 0)
        return true
    }

    /// The term keeps its place. False when the new name is empty or another term's, or the old one is not there.
    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        let new = Self.clean(new)
        guard !new.isEmpty, let i = terms.firstIndex(of: old) else { return false }
        if let other = index(of: new), other != i { return false }
        terms[i] = new
        return true
    }

    public mutating func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }

    /// The terms that are sent: the rest fell off the end, behind the corrected words and the limit.
    public func inUse(corrections: [MeilingCorrection], limit: Int) -> Set<String> {
        let sent = Set(MeilingCorrections.vocabulary(corrections, terms: terms, limit: limit).map { $0.lowercased() })
        return Set(terms.filter { sent.contains($0.lowercased()) })
    }

    /// A plain JSON string array, one term per line (MeilingSoftFiles.terms reads it back).
    public func fileData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(terms)) ?? Data("[]".utf8)
    }
}
