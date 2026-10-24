import CodeIslandCore
import CoreGraphics
import Foundation

// meiling-sim: types one 美玲 frame the way the Tab5 would, so aism + the input method can be benched without the
// board. The real Tab5 waits for the Scroll Lock ack; this waits a fixed time instead.
//   meiling-sim dictation "<text>" [--wait-ms 300] [--seq N]
//   meiling-sim caption "<text>"   [--wait-ms 50]  [--seq N]
let args = CommandLine.arguments
guard args.count >= 3, let kind: MeilingFrameKind = ["dictation": .dictation, "caption": .caption][args[1]] else {
    FileHandle.standardError.write(Data("usage: meiling-sim dictation|caption \"text\" [--wait-ms N] [--seq N]\n".utf8))
    exit(2)
}
func option(_ name: String, _ fallback: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return fallback }
    return v
}
let text = args[2].replacingOccurrences(of: "\\n", with: "\n")
let wait = option("--wait-ms", kind == .dictation ? 300 : 50)
let seq = UInt16(option("--seq", Int(Date().timeIntervalSince1970) % 1024))
guard let frame = MeilingKeyCodec.encodeFrame(kind: kind, seq: seq, text: text) else {
    FileHandle.standardError.write(Data("text too long (max \(MeilingKeyCodec.maxScalars) scalars)\n".utf8))
    exit(1)
}
let source = CGEventSource(stateID: .hidSystemState)
func type(_ keyCodes: [UInt16]) {
    for keyCode in keyCodes {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
            usleep(1000)
        }
    }
}
let start = Date()
type(frame.head)
usleep(useconds_t(wait * 1000))
type(frame.tail)
print("sent \(kind) seq=\(seq) keys=\(frame.head.count + frame.tail.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
