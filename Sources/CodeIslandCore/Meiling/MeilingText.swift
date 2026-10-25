import Foundation

public enum MeilingText {
    /// transcribe-live spaces CJK characters apart ("我 们 先"): drop spaces between CJK characters and punctuation,
    /// keep them next to Latin letters and digits (luna-work app/meiling/transcript.cpp compactCjkSpaces).
    public static func compactCjkSpaces(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in s.enumerated() {
            if c == " ", i > 0, i + 1 < s.count {
                let l = s[i - 1], r = s[i + 1]
                if joinable(l), joinable(r), cjk(l) || cjk(r) { continue }
            }
            out.append(c)
        }
        return String(out)
    }

    /// live-translate transcribes Chinese input as Traditional (docs/meiling/p0-probe.md).
    public static func simplified(_ text: String) -> String {
        let s = NSMutableString(string: text)
        CFStringTransform(s, nil, "Hant-Hans" as CFString, false)
        return s as String
    }

    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func cjk(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x3000...0x303F).contains(v) || (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    static func joinable(_ c: Unicode.Scalar) -> Bool {
        if cjk(c) { return true }
        return c.value < 0x80 && c.value > 0x20 && !CharacterSet.alphanumerics.contains(c)
    }
}

/// Joins live-translate transcription fragments into caption lines (luna-work app/meiling/meeting.cpp): a line
/// ends at sentence punctuation in the translation or after 1.5 s without fragments (the Tab5 uses 800 ms; on the
/// Mac the owner wanted whole sentences over speed, 2026-10-25).
public struct MeilingCaptionAssembler: Sendable {
    public static let quietMs: UInt64 = 1500

    public struct Line: Equatable, Sendable {
        public let text: String, original: String
    }

    private var input = "", output = ""
    private var lastMs: UInt64 = 0

    public init() {}

    public var pending: Line? {
        input.isEmpty && output.isEmpty ? nil : Line(text: output.trimmed, original: input.trimmed)
    }

    /// Returns a finished line when this fragment ends a sentence.
    public mutating func add(input: String, output: String, atMs now: UInt64) -> Line? {
        guard !input.isEmpty || !output.isEmpty else { return nil }
        self.input += input
        self.output += output
        lastMs = now
        return Self.endsSentence(self.output.trimmed) ? flush() : nil
    }

    public mutating func tick(atMs now: UInt64) -> Line? {
        guard !output.isEmpty, now - lastMs > Self.quietMs else { return nil }
        return flush()
    }

    public mutating func flush() -> Line? {
        let line = Line(text: output.trimmed, original: input.trimmed)
        input = ""
        output = ""
        return line.text.isEmpty && line.original.isEmpty ? nil : line
    }

    static func endsSentence(_ s: String) -> Bool {
        [".", "?", "!", "。", "？", "！"].contains { s.hasSuffix($0) }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
