import Foundation

/// 美玲 key codec (twin of luna-work `app/meiling/key_codec.cpp`; shared vectors in
/// `Tests/CodeIslandCoreTests/Fixtures/meiling_keycodec_vectors.json`).
///
/// Frame: open (dictation F13 F15 F13 / caption F14 F15 F14) · [the Tab5 waits for our ack] · version(=0) · seq
/// (2 symbols) · payload · CRC-16/CCITT-FALSE (4 symbols) · close F15 F15. Symbols are base32 "a…z2…7" typed with no
/// modifier. Payload per scalar: CJK U+4E00–9FFF 3 symbols, ASCII 0x20–0x7E and "\n" 2 symbols, other 5 symbols.
public enum MeilingFrameKind: Equatable, Sendable { case dictation, caption }

public enum MeilingKeyCodec {
    public static let f13: UInt16 = 105, f14: UInt16 = 107, f15: UInt16 = 113
    public static let maxScalars = 256

    /// macOS virtual keycodes (US ANSI) of the 32 symbols "abcdefghijklmnopqrstuvwxyz234567".
    static let symbolKeyCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17,
                                           32, 9, 13, 7, 16, 6, 19, 20, 21, 23, 22, 26]
    static let symbolForKeyCode: [UInt16: UInt8] = Dictionary(
        uniqueKeysWithValues: symbolKeyCodes.enumerated().map { ($0.element, UInt8($0.offset)) })

    public static func symbol(forKeyCode keyCode: UInt16) -> UInt8? { symbolForKeyCode[keyCode] }

    /// HID usage (as sent by the Tab5) → macOS keycode, for the alphabet and the three markers.
    public static func macKeyCode(forUsage usage: UInt8) -> UInt16? {
        switch usage {
        case 0x04...0x1D: return symbolKeyCodes[Int(usage - 0x04)]
        case 0x1F...0x24: return symbolKeyCodes[26 + Int(usage - 0x1F)]
        case 0x68: return f13
        case 0x69: return f14
        case 0x6A: return f15
        default: return nil
        }
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    static func symbols(of scalar: Unicode.Scalar) -> [UInt8] {
        let c = scalar.value
        if (0x4E00...0x9FFF).contains(c) {
            let o = c - 0x4E00
            return [UInt8(o >> 10), UInt8((o >> 5) & 31), UInt8(o & 31)]
        }
        if (0x20...0x7E).contains(c) || c == 0x0A {
            let x = c == 0x0A ? 95 : c - 0x20
            return [UInt8(21 + (x >> 5)), UInt8(x & 31)]
        }
        return [UInt8(24 + (c >> 20)), UInt8((c >> 15) & 31), UInt8((c >> 10) & 31), UInt8((c >> 5) & 31), UInt8(c & 31)]
    }

    /// The payload symbols (CRC excluded) back to text; nil when malformed.
    public static func decodePayload(_ symbols: [UInt8]) -> String? {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < symbols.count {
            let s0 = symbols[i]
            guard s0 < 32 else { return nil }
            let length = s0 <= 20 ? 3 : s0 <= 23 ? 2 : 5
            guard i + length <= symbols.count else { return nil }
            let rest = symbols[(i + 1)..<(i + length)].map(UInt32.init)
            guard rest.allSatisfy({ $0 < 32 }) else { return nil }
            let value: UInt32
            switch length {
            case 3:
                value = 0x4E00 + (UInt32(s0) << 10) + (rest[0] << 5) + rest[1]
                guard value <= 0x9FFF else { return nil }
            case 2:
                let x = (UInt32(s0 - 21) << 5) + rest[0]
                guard x <= 95 else { return nil }
                value = x == 95 ? 0x0A : 0x20 + x
            default:
                value = (UInt32(s0 - 24) << 20) | (rest[0] << 15) | (rest[1] << 10) | (rest[2] << 5) | rest[3]
            }
            guard let scalar = Unicode.Scalar(value) else { return nil }
            scalars.append(scalar)
            i += length
        }
        return String(scalars)
    }

    /// Keycode form of a frame, split at the ack point (used by `meiling-sim`).
    public static func encodeFrame(kind: MeilingFrameKind, seq: UInt16, text: String) -> (head: [UInt16], tail: [UInt16])? {
        guard seq < 1024, text.unicodeScalars.count <= maxScalars else { return nil }
        let marker = kind == .dictation ? f13 : f14
        let head = [marker, f15, marker]  // only marker keys before the ack (review C1)
        var body: [UInt8] = [0, UInt8(seq >> 5), UInt8(seq & 31)] + text.unicodeScalars.flatMap(symbols(of:))
        let crc = crc16(Array(text.utf8))
        body += [UInt8((crc >> 15) & 31), UInt8((crc >> 10) & 31), UInt8((crc >> 5) & 31), UInt8(crc & 31)]
        return (head, body.map { symbolKeyCodes[Int($0)] } + [f15, f15])
    }
}
