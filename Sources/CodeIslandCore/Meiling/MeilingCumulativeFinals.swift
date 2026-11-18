import Foundation

/// What is new in a transcribe-live final. Since 2026-11-18 every `inputTranscription` repeats the whole session so
/// far (across releases too, until the socket closes), and the model sometimes rewrites earlier words in it; before
/// that each final was one sentence. Typing them as they come typed everything again with each sentence.
/// The last final is lined up against the new one (edit distance to its best-matching prefix) and only what follows
/// is returned: rewritten words are skipped, since they are already typed and cannot be taken back. A final that
/// does not resemble the last one at all is a sentence of its own (the old behaviour, or a new connection) and is
/// returned whole. One per connection: `reset` when a new one is set up.
public struct MeilingCumulativeFinals {
    private var heard: [Character] = []

    public init() {}

    public mutating func reset() { heard = [] }

    public mutating func fresh(in final: String) -> String {
        let now = Array(final)
        defer { heard = now }
        guard !heard.isEmpty else { return final }
        var same = 0
        while same < heard.count, same < now.count, heard[same] == now[same] { same += 1 }
        let old = heard[same...], new = Array(now[same...])
        // row[j]: edits that turn what is left of the last final into the first j characters of the new rest.
        var row = Array(0...new.count), next = row
        for a in old {
            next[0] = row[0] + 1
            for (j, b) in new.enumerated() {
                next[j + 1] = min(row[j] + (a == b ? 0 : 1), row[j + 1] + 1, next[j] + 1)
            }
            swap(&row, &next)
        }
        // On a tie the longer match: a word swapped for another is a rewrite, not something new.
        var covered = 0
        for j in row.indices where row[j] <= row[covered] { covered = j }
        if row[covered] * 2 > heard.count { return final }
        return String(new[covered...]).trimmingCharacters(in: .whitespaces)
    }
}
