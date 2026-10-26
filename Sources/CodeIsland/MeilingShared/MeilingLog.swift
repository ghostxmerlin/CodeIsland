import Foundation

/// ~/Library/Logs/AISM/meiling.log, shared by the Tab5 hardware mode and the software mode: phases and latencies,
/// never the dictated text. Past 2 MB it moves to meiling.log.1 (one older file is kept).
struct MeilingLog {
    static let maxBytes = 2 << 20

    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AISM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meiling.log")
    }()

    func write(_ line: String) {
        let url = Self.url
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
