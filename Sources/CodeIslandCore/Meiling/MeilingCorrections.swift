import Foundation

/// One learned correction: what the recognizer wrote for the owner's voice (`heard`) and what was meant
/// (`right`), e.g. 美林 → 美玲. Applied to every later sentence before it is typed, and `right` goes to the front
/// of the vocabulary. The Gemini Live API takes no pronunciations, so these pairs are how "this sound means that
/// word" is learned: from the owner's own corrections (2026-10-25).
public struct MeilingCorrection: Codable, Equatable, Identifiable, Sendable {
    public var heard: String
    public var right: String
    public var count: Int
    public var enabled: Bool
    public var lastUsed: Date

    public var id: String { heard + "\u{1F}" + right }

    public init(heard: String, right: String, count: Int = 1, enabled: Bool = true, lastUsed: Date = Date()) {
        self.heard = heard
        self.right = right
        self.count = count
        self.enabled = enabled
        self.lastUsed = lastUsed
    }
}

public enum MeilingCorrections {
    /// Longer rewrites are a different sentence, not a misheard word.
    public static let maxSpan = 12
    /// More of the sentence changed than this: it was rewritten, and nothing is learned from it.
    public static let maxChangedShare = 0.4
    /// Common characters a two-character widening should not lean on (到地板 → the pair is 地板, not 到地).
    static let particles = Set("的了在到把和与是我你他她它们这那个就也都还看用说要会能吗呢吧啊上下里中给对从被让很再又")

    /// The words changed between what was heard and what the owner corrected it to. A change inside a Latin word
    /// takes the whole word ("Mic" → "Mac" in "MicBook" gives MicBook → MacBook); a CJK change is widened to at
    /// least two characters on the heard side, so one common character (林) is never replaced everywhere.
    public static func pairs(heard original: String, corrected: String) -> [(heard: String, right: String)] {
        let a = Array(original), b = Array(corrected)
        let found = merged(hunks(a, b), a)
        let changed = found.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        guard Double(changed) <= maxChangedShare * Double(max(a.count, b.count, 1)) else { return [] }
        var result: [(String, String)] = []
        for var hunk in found {
            widenToWords(&hunk, a, b)
            while hunk.a.count < 2, hunk.a.lowerBound > 0 || hunk.a.upperBound < a.count {
                let leftOK = hunk.a.lowerBound > 0 && hunk.b.lowerBound > 0
                let rightOK = hunk.a.upperBound < a.count && hunk.b.upperBound < b.count
                let leftIsParticle = leftOK && particles.contains(a[hunk.a.lowerBound - 1])
                if leftOK, !(leftIsParticle && rightOK) {
                    hunk.a = (hunk.a.lowerBound - 1)..<hunk.a.upperBound
                    hunk.b = (hunk.b.lowerBound - 1)..<hunk.b.upperBound
                } else if rightOK {
                    hunk.a = hunk.a.lowerBound..<(hunk.a.upperBound + 1)
                    hunk.b = hunk.b.lowerBound..<(hunk.b.upperBound + 1)
                } else {
                    break
                }
            }
            let trim = CharacterSet.whitespaces.union(.punctuationCharacters)
            let heard = String(a[hunk.a]).trimmingCharacters(in: trim)
            let right = String(b[hunk.b]).trimmingCharacters(in: trim)
            guard !heard.isEmpty, !right.isEmpty, heard != right,
                  heard.count <= maxSpan, right.count <= maxSpan else { continue }
            if !result.contains(where: { $0.0 == heard && $0.1 == right }) { result.append((heard, right)) }
        }
        return result
    }

    /// Every enabled correction, longest `heard` first. An occurrence that is already part of `right` is left
    /// alone (Mac → MacBook must not turn MacBook into MacBookBook).
    public static func apply(_ corrections: [MeilingCorrection], to text: String) -> String {
        var out = text
        for c in corrections.filter(\.enabled).sorted(by: { $0.heard.count > $1.heard.count }) {
            out = replace(c.heard, with: c.right, in: out)
        }
        return out
    }

    /// Records the pairs of one correction: a known pair counts up, a new one is added (enabled).
    public static func learn(_ found: [(heard: String, right: String)], into list: inout [MeilingCorrection],
                             now: Date = Date()) {
        for (heard, right) in found {
            if let i = list.firstIndex(where: { $0.heard == heard && $0.right == right }) {
                list[i].count += 1
                list[i].lastUsed = now
            } else {
                list.append(MeilingCorrection(heard: heard, right: right, lastUsed: now))
            }
        }
    }

    /// The vocabulary: corrected words first (most recent first), then `terms`, without repeats, at most `limit`.
    public static func vocabulary(_ corrections: [MeilingCorrection], terms: [String], limit: Int) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let learned = corrections.filter(\.enabled).sorted { $0.lastUsed > $1.lastUsed }.map(\.right)
        for term in learned + terms where seen.insert(term.lowercased()).inserted {
            out.append(term)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: diff

    private struct Hunk {
        var a: Range<Int>, b: Range<Int>
    }

    /// The changed runs of an LCS alignment (sentences are short: O(n·m) is fine).
    private static func hunks(_ a: [Character], _ b: [Character]) -> [Hunk] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0
        var open: (Int, Int)?
        func close() {
            if let (si, sj) = open { out.append(Hunk(a: si..<i, b: sj..<j)) }
            open = nil
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close()
                i += 1
                j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        close()
        return out
    }

    /// Hunks only a Latin word or one character apart belong to the same misheard word (SIDF → ESP-IDF aligns its
    /// S and IDF, leaving two hunks inside one word).
    private static func merged(_ hunks: [Hunk], _ a: [Character]) -> [Hunk] {
        var out: [Hunk] = []
        for h in hunks {
            if let last = out.last {
                let gap = a[last.a.upperBound..<h.a.lowerBound]
                if gap.count <= 1 || gap.allSatisfy(isWordChar) {
                    out[out.count - 1] = Hunk(a: last.a.lowerBound..<h.a.upperBound, b: last.b.lowerBound..<h.b.upperBound)
                    continue
                }
            }
            out.append(h)
        }
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// A hunk with a Latin letter in it grows to the whole word on both sides (the characters just outside a hunk
    /// are aligned, so one side decides).
    private static func widenToWords(_ h: inout Hunk, _ a: [Character], _ b: [Character]) {
        guard h.a.contains(where: { isWordChar(a[$0]) }) || h.b.contains(where: { isWordChar(b[$0]) }) else { return }
        var (al, au, bl, bu) = (h.a.lowerBound, h.a.upperBound, h.b.lowerBound, h.b.upperBound)
        while al > 0, bl > 0, isWordChar(a[al - 1]) {
            al -= 1
            bl -= 1
        }
        while au < a.count, bu < b.count, isWordChar(a[au]) {
            au += 1
            bu += 1
        }
        h = Hunk(a: al..<au, b: bl..<bu)
    }

    private static func replace(_ heard: String, with right: String, in text: String) -> String {
        guard !heard.isEmpty, text.contains(heard) else { return text }
        // Spans of `right` already in the text are kept as they are.
        var keep: [Range<String.Index>] = []
        if right.contains(heard) {
            var from = text.startIndex
            while let r = text.range(of: right, range: from..<text.endIndex) {
                keep.append(r)
                from = r.upperBound
            }
        }
        var out = "", cursor = text.startIndex
        var from = text.startIndex
        while let r = text.range(of: heard, range: from..<text.endIndex) {
            if keep.contains(where: { $0.overlaps(r) }) {
                from = r.upperBound
                continue
            }
            out += text[cursor..<r.lowerBound] + right
            cursor = r.upperBound
            from = r.upperBound
        }
        out += text[cursor..<text.endIndex]
        return out
    }
}
