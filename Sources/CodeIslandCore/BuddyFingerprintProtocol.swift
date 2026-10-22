import CryptoKit
import Foundation
import Security

// Buddy fingerprint channel (phase 1), spoken with aism over the regular
// Buddy characteristics. See docs/buddy-fingerprint-protocol.md.
//
//   request  Mac → Atom: D0 op reqId payload
//   reply    Atom → Mac: D0 (op|0x80) reqId result payload
//   event    Atom → Mac: D0 70 reqId result type data

public enum BuddyFingerprintOp: UInt8, Sendable {
    case status = 0x01
    case enrollBegin = 0x21
    case cancel = 0x22
    case list = 0x23
    case verify = 0x24
    case delete = 0x25
    case attestSet = 0x40
    case attestDelete = 0x41
    case attestStatus = 0x42
    case unlockChallenge = 0x43
}

public enum BuddyFingerprintResult: Equatable, Sendable {
    case ok, waitConfirm, invalid, busy, noSensor, sensorError, timeout, cancelled
    case noAttest, noMatch, noBinding, duplicate, full
    case unknown(UInt8)

    private static let known: [(UInt8, BuddyFingerprintResult)] = [
        (0, .ok), (1, .waitConfirm), (2, .invalid), (3, .busy), (6, .noSensor), (7, .sensorError),
        (8, .timeout), (9, .cancelled), (14, .noAttest), (15, .noMatch), (16, .noBinding),
        (17, .duplicate), (18, .full),
    ]

    public init(raw: UInt8) {
        self = Self.known.first { $0.0 == raw }?.1 ?? .unknown(raw)
    }

    public var raw: UInt8 {
        if case .unknown(let raw) = self { return raw }
        return Self.known.first { $0.1 == self }!.0
    }
}

public enum BuddyFingerprintRequest {
    public static let unlockChunkBytes = 16

    public static func encode(op: BuddyFingerprintOp, reqId: UInt8, payload: Data = Data()) -> Data {
        var data = Data([ESP32Protocol.fingerprintMarker, op.rawValue, reqId])
        data.append(payload)
        return data
    }

    /// Slot as LE16; `nil` is `FF FF` (first free slot / every slot).
    public static func slotPayload(_ slot: Int?) -> Data {
        guard let slot else { return Data([0xFF, 0xFF]) }
        let value = UInt16(clamping: slot)
        return Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// The 32-byte nonce split into offset 00 and offset 10, same reqId.
    public static func unlockChallengeFrames(reqId: UInt8, nonce: Data) -> [Data] {
        let bytes = Array(nonce)
        return stride(from: 0, to: bytes.count, by: unlockChunkBytes).map { offset in
            let chunk = bytes[offset..<min(offset + unlockChunkBytes, bytes.count)]
            return encode(op: .unlockChallenge, reqId: reqId, payload: Data([UInt8(offset)] + chunk))
        }
    }
}

public struct BuddyFingerprintReply: Equatable, Sendable {
    public let op: BuddyFingerprintOp?
    public let rawOp: UInt8
    public let reqId: UInt8
    public let result: BuddyFingerprintResult
    public let payload: Data
}

public struct BuddyFingerprintEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case enroll, unlock, verify
        case other(UInt8)

        init(raw: UInt8) {
            switch raw {
            case 1: self = .enroll
            case 2: self = .unlock
            case 4: self = .verify
            default: self = .other(raw)
            }
        }
    }

    public let reqId: UInt8
    public let result: BuddyFingerprintResult
    public let kind: Kind
    public let data: Data

    public init(reqId: UInt8, result: BuddyFingerprintResult, kind: Kind, data: Data) {
        self.reqId = reqId
        self.result = result
        self.kind = kind
        self.data = data
    }

    /// Whether the operation this event belongs to is over.
    public var isTerminal: Bool {
        switch kind {
        case .enroll: return result != .ok || data.first == BuddyEnrollProgress.doneStage
        // A wrong finger keeps the unlock round going.
        case .unlock: return result != .noMatch
        case .verify, .other: return true
        }
    }

    /// Matched slot from a verify event; `FF FF` (no match) is `nil`.
    public static func verifySlot(eventData: Data) -> Int? {
        let bytes = Array(eventData)
        guard bytes.count >= 2 else { return nil }
        let slot = Int(bytes[0]) | Int(bytes[1]) << 8
        return slot == 0xFFFF ? nil : slot
    }
}

public enum BuddyFingerprintFrame: Equatable, Sendable {
    case reply(BuddyFingerprintReply)
    case event(BuddyFingerprintEvent)

    private static let eventOp: UInt8 = 0x70

    public init?(payload: Data) {
        let bytes = Array(payload)
        guard bytes.count >= 4, bytes[0] == ESP32Protocol.fingerprintMarker, bytes[2] != 0 else { return nil }
        let result = BuddyFingerprintResult(raw: bytes[3])
        if bytes[1] == Self.eventOp {
            guard bytes.count >= 5 else { return nil }
            self = .event(BuddyFingerprintEvent(reqId: bytes[2], result: result,
                                                kind: .init(raw: bytes[4]), data: Data(bytes[5...])))
        } else if bytes[1] & 0x80 != 0 {
            let rawOp = bytes[1] & 0x7F
            self = .reply(BuddyFingerprintReply(op: BuddyFingerprintOp(rawValue: rawOp), rawOp: rawOp,
                                                reqId: bytes[2], result: result, payload: Data(bytes[4...])))
        } else {
            return nil
        }
    }
}

public struct BuddyFingerprintStatus: Equatable, Sendable {
    public let version: UInt8
    public let present: Bool
    /// `nil` while the module hasn't reported a count yet.
    public let count: Int?
    public let hasAttest: Bool
    /// 0 idle, 1 enroll, 2 verify, 3 unlock, 4 approval.
    public let activeOp: UInt8

    public init(version: UInt8, present: Bool, count: Int?, hasAttest: Bool, activeOp: UInt8) {
        self.version = version
        self.present = present
        self.count = count
        self.hasAttest = hasAttest
        self.activeOp = activeOp
    }

    public init?(payload: Data) {
        let bytes = Array(payload)
        guard bytes.count >= 5 else { return nil }
        self.init(version: bytes[0], present: bytes[1] != 0, count: bytes[2] == 0xFF ? nil : Int(bytes[2]),
                  hasAttest: bytes[3] != 0, activeOp: bytes[4])
    }
}

public struct BuddyFingerprintAttestStatus: Equatable, Sendable {
    public let hasAttest: Bool
    public let hasFinger: Bool
    /// SHA-256(K)[0:8] as the device sees it.
    public let keyFingerprint: Data

    public init(hasAttest: Bool, hasFinger: Bool, keyFingerprint: Data) {
        self.hasAttest = hasAttest
        self.hasFinger = hasFinger
        self.keyFingerprint = keyFingerprint
    }

    public init?(payload: Data) {
        let bytes = Array(payload)
        guard bytes.count >= 10 else { return nil }
        self.init(hasAttest: bytes[0] != 0, hasFinger: bytes[1] != 0, keyFingerprint: Data(bytes[2..<10]))
    }
}

public enum BuddyFingerprintSlots {
    public static let slotCount = 100

    public static func slots(fromBitmap bitmap: Data) -> [Int] {
        let bytes = Array(bitmap)
        return (0..<slotCount).filter { slot in
            slot / 8 < bytes.count && bytes[slot / 8] & (1 << (slot % 8)) != 0
        }
    }
}

public struct BuddyEnrollProgress: Equatable, Sendable {
    public static let doneStage: UInt8 = 5

    /// 1 place finger, 3 processing, 2 lift finger, 4 saving, 5 done.
    public let stage: UInt8
    /// Presses completed so far, out of 6.
    public let sample: UInt8
    public let slot: Int

    public init(stage: UInt8, sample: UInt8, slot: Int) {
        self.stage = stage
        self.sample = sample
        self.slot = slot
    }

    public init?(eventData: Data) {
        let bytes = Array(eventData)
        guard bytes.count >= 4 else { return nil }
        self.init(stage: bytes[0], sample: bytes[1], slot: Int(bytes[2]) | Int(bytes[3]) << 8)
    }
}

/// Phase-1 attestation: a fixed, public key shared by every aism. It proves
/// nothing about who is on the other end; it only exercises the flow.
public enum BuddyFingerprintAttestation {
    public static let fixedKey = Data("aism-fingerprint-phase1-test-key".utf8)
    public static let expectedKeyFingerprint = keyFingerprint(fixedKey)
    public static let tagBytes = 14
    private static let label = Data("EXIA-UNLOCK-v1".utf8) + Data([0])

    public static func keyFingerprint(_ key: Data) -> Data {
        Data(SHA256.hash(data: key).prefix(8))
    }

    public static func tag(nonce: Data, key: Data = fixedKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: label + nonce, using: SymmetricKey(data: key))
        return Data(mac).prefix(tagBytes)
    }

    /// Constant-time compare against the expected tag.
    public static func verify(tag: Data, nonce: Data, key: Data = fixedKey) -> Bool {
        guard tag.count == tagBytes else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self.tag(nonce: nonce, key: key), tag) { diff |= a ^ b }
        return diff == 0
    }

    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}
