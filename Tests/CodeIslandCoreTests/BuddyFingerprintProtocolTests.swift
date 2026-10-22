import XCTest
@testable import CodeIslandCore

/// Byte sequences are the real-device captures in
/// docs/buddy-fingerprint-protocol.md section 7.
final class BuddyFingerprintProtocolTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        let digits = Array(string.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(digits[$0...$0 + 1]), radix: 16)!
        })
    }

    private func reply(_ string: String) -> BuddyFingerprintReply? {
        guard case .reply(let reply)? = BuddyFingerprintFrame(payload: hex(string)) else { return nil }
        return reply
    }

    private func event(_ string: String) -> BuddyFingerprintEvent? {
        guard case .event(let event)? = BuddyFingerprintFrame(payload: hex(string)) else { return nil }
        return event
    }

    func testStatusRequestAndReply() throws {
        XCTAssertEqual(BuddyFingerprintRequest.encode(op: .status, reqId: 1), hex("d0 01 01"))

        let reply = try XCTUnwrap(reply("d0 81 01 00 01 01 05 01 00"))
        XCTAssertEqual(reply.op, .status)
        XCTAssertEqual(reply.reqId, 1)
        XCTAssertEqual(reply.result, .ok)
        let status = try XCTUnwrap(BuddyFingerprintStatus(payload: reply.payload))
        XCTAssertEqual(status, BuddyFingerprintStatus(version: 1, present: true, count: 5, hasAttest: true, activeOp: 0))
    }

    func testStatusUnknownCountIsNil() throws {
        let status = try XCTUnwrap(BuddyFingerprintStatus(payload: hex("01 01 ff 01 00")))
        XCTAssertNil(status.count)
    }

    func testListBitmapSlots() throws {
        let reply = try XCTUnwrap(reply("d0 a3 01 00 1f 00 00 00 00 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(reply.op, .list)
        XCTAssertEqual(BuddyFingerprintSlots.slots(fromBitmap: reply.payload), [0, 1, 2, 3, 4])
        XCTAssertEqual(BuddyFingerprintSlots.slots(fromBitmap: hex("00 00 00 00 00 00 00 00 00 00 00 00 ff")), [96, 97, 98, 99])
    }

    func testEnrollRequestAndProgressEvents() throws {
        XCTAssertEqual(BuddyFingerprintRequest.encode(op: .enrollBegin, reqId: 1,
                                                      payload: BuddyFingerprintRequest.slotPayload(nil)),
                       hex("d0 21 01 ff ff"))
        XCTAssertEqual(reply("d0 a1 01 00")?.op, .enrollBegin)

        let first = try XCTUnwrap(event("d0 70 01 00 01 01 00 05 00"))
        XCTAssertEqual(first.kind, .enroll)
        XCTAssertEqual(first.result, .ok)
        XCTAssertEqual(BuddyEnrollProgress(eventData: first.data), BuddyEnrollProgress(stage: 1, sample: 0, slot: 5))
        XCTAssertFalse(first.isTerminal)

        let done = try XCTUnwrap(event("d0 70 01 00 01 05 06 05 00"))
        XCTAssertTrue(done.isTerminal)

        let duplicate = try XCTUnwrap(event("d0 70 01 11 01 00 06 05 00"))
        XCTAssertEqual(duplicate.result, .duplicate)
        XCTAssertTrue(duplicate.isTerminal)
    }

    func testVerifyEvent() throws {
        XCTAssertEqual(BuddyFingerprintRequest.encode(op: .verify, reqId: 1), hex("d0 24 01"))
        let match = try XCTUnwrap(event("d0 70 01 00 04 05 00"))
        XCTAssertEqual(match.kind, .verify)
        XCTAssertEqual(BuddyFingerprintEvent.verifySlot(eventData: match.data), 5)
        XCTAssertTrue(match.isTerminal)
        XCTAssertNil(BuddyFingerprintEvent.verifySlot(eventData: hex("ff ff")))
    }

    func testDeleteRequest() {
        XCTAssertEqual(BuddyFingerprintRequest.encode(op: .delete, reqId: 1,
                                                      payload: BuddyFingerprintRequest.slotPayload(5)),
                       hex("d0 25 01 05 00"))
        XCTAssertEqual(BuddyFingerprintRequest.slotPayload(99), hex("63 00"))
    }

    func testUnlockChallengeFramesAndTagVector() throws {
        let nonce = hex("55eb4843d3598a39d141d7d1f5e3256f 9474b60fc09492010a40b780dd661445")
        XCTAssertEqual(BuddyFingerprintRequest.unlockChallengeFrames(reqId: 1, nonce: nonce), [
            hex("d0 43 01 00 55 eb 48 43 d3 59 8a 39 d1 41 d7 d1 f5 e3 25 6f"),
            hex("d0 43 01 10 94 74 b6 0f c0 94 92 01 0a 40 b7 80 dd 66 14 45"),
        ])
        XCTAssertEqual(reply("d0 c3 01 00 10")?.payload, hex("10"))

        let tag = hex("e9e2da62848eac882e7bbd90eebe")
        XCTAssertEqual(BuddyFingerprintAttestation.tag(nonce: nonce), tag)

        let noMatch = try XCTUnwrap(event("d0 70 01 0f 02"))
        XCTAssertEqual(noMatch.kind, .unlock)
        XCTAssertEqual(noMatch.result, .noMatch)
        XCTAssertFalse(noMatch.isTerminal)

        let ok = try XCTUnwrap(event("d0 70 01 00 02 e9 e2 da 62 84 8e ac 88 2e 7b bd 90 ee be"))
        XCTAssertTrue(ok.isTerminal)
        XCTAssertEqual(ok.data, tag)
        XCTAssertTrue(BuddyFingerprintAttestation.verify(tag: ok.data, nonce: nonce))
    }

    func testFixedKeyFingerprint() {
        XCTAssertEqual(BuddyFingerprintAttestation.fixedKey, Data("aism-fingerprint-phase1-test-key".utf8))
        XCTAssertEqual(BuddyFingerprintAttestation.keyFingerprint(BuddyFingerprintAttestation.fixedKey),
                       hex("d9dfb16ead4ef7db"))
        XCTAssertEqual(BuddyFingerprintAttestation.expectedKeyFingerprint, hex("d9dfb16ead4ef7db"))
    }

    func testAttestStatusReply() throws {
        let reply = try XCTUnwrap(reply("d0 c2 02 00 01 01 d9 df b1 6e ad 4e f7 db"))
        XCTAssertEqual(reply.op, .attestStatus)
        XCTAssertEqual(BuddyFingerprintAttestStatus(payload: reply.payload),
                       BuddyFingerprintAttestStatus(hasAttest: true, hasFinger: true, keyFingerprint: hex("d9dfb16ead4ef7db")))
    }

    func testVerifyRejectsWrongOrShortTag() {
        let nonce = hex("55eb4843d3598a39d141d7d1f5e3256f 9474b60fc09492010a40b780dd661445")
        var flipped = hex("e9e2da62848eac882e7bbd90eebe")
        flipped[flipped.startIndex + 13] ^= 0x01
        XCTAssertFalse(BuddyFingerprintAttestation.verify(tag: flipped, nonce: nonce))
        XCTAssertFalse(BuddyFingerprintAttestation.verify(tag: hex("e9e2da62848eac882e7bbd90ee"), nonce: nonce))
    }

    func testNoncesAreFreshAndFullLength() {
        let a = BuddyFingerprintAttestation.makeNonce()
        let b = BuddyFingerprintAttestation.makeNonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testCancelSequence() throws {
        XCTAssertEqual(BuddyFingerprintRequest.encode(op: .cancel, reqId: 2), hex("d0 22 02"))
        let ack = try XCTUnwrap(reply("d0 a2 02 00"))
        XCTAssertEqual(ack.op, .cancel)
        XCTAssertEqual(ack.reqId, 2)

        let cancelled = try XCTUnwrap(event("d0 70 01 09 02"))
        XCTAssertEqual(cancelled.reqId, 1)
        XCTAssertEqual(cancelled.result, .cancelled)
        XCTAssertTrue(cancelled.isTerminal)
    }

    func testResultCodesRoundTrip() {
        let known: [(UInt8, BuddyFingerprintResult)] = [
            (0, .ok), (1, .waitConfirm), (2, .invalid), (3, .busy), (6, .noSensor), (7, .sensorError),
            (8, .timeout), (9, .cancelled), (14, .noAttest), (15, .noMatch), (16, .noBinding),
            (17, .duplicate), (18, .full),
        ]
        for (raw, result) in known {
            XCTAssertEqual(BuddyFingerprintResult(raw: raw), result)
            XCTAssertEqual(result.raw, raw)
        }
        XCTAssertEqual(BuddyFingerprintResult(raw: 42), .unknown(42))
        XCTAssertEqual(BuddyFingerprintResult.unknown(42).raw, 42)
    }

    func testMalformedFingerprintFramesAreNil() {
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("d0")))
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("d0 81 01")))
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("d0 81 00 00")))
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("d0 70 01 00")))
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("d0 01 01 00")), "requests never come back up")
        XCTAssertNil(BuddyFingerprintFrame(payload: hex("e0")))
    }

    func testUplinkEventRoutesD0() throws {
        let event = BuddyUplinkEvent(payload: hex("d0 81 01 00 01 01 05 01 00"))
        guard case .fingerprint(.reply(let reply))? = event else {
            return XCTFail("expected a fingerprint reply, got \(String(describing: event))")
        }
        XCTAssertEqual(reply.op, .status)
        XCTAssertNil(BuddyUplinkEvent(payload: hex("d0 81")))
        XCTAssertEqual(BuddyUplinkEvent(payload: hex("f0")), .command(.approveCurrentPermission))
        XCTAssertEqual(BuddyUplinkEvent(payload: hex("e0")), .pairResponse(.accepted))
    }
}
