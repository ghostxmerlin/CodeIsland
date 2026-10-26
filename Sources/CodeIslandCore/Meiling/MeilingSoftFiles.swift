import Foundation

/// The software mode's file formats, shared by AISM and the meiling-soft bench.
public enum MeilingSoftFiles {
    /// The key file: `GEMINI_API_KEY=…` on its own line (quotes and spaces trimmed), like luna-work's .env.
    public static func apiKey(fromEnv text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("GEMINI_API_KEY=") {
            let key = line.dropFirst("GEMINI_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            return key.isEmpty ? nil : key
        }
        return nil
    }

    /// The vocabulary file: a plain JSON string array, or [{"term": …}].
    public static func terms(from data: Data) -> [String] {
        if let objects = try? JSONDecoder().decode([[String: String]].self, from: data) { return objects.compactMap { $0["term"] } }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
