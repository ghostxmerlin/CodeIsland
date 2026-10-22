import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Atom's side is replayed from docs/buddy-fingerprint-protocol.md section 7.
@MainActor
final class BuddyFingerprintManagerTests: XCTestCase {
    private var h: FingerprintChannelHarness!
    private var manager: BuddyFingerprintManager!

    override func setUp() async throws {
        try await super.setUp()
        h = FingerprintChannelHarness()
        h.startSupported()
        manager = BuddyFingerprintManager(channel: h.channel)
    }

    private func reply(_ format: String) {
        h.receive(String(format: format, h.lastReqId))
    }

    func testRefreshListParsesBitmap() {
        manager.refreshList()
        XCTAssertEqual(h.sent.last?[1], 0x23)
        reply("d0 a3 %02x 00 1f 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(manager.slots, [0, 1, 2, 3, 4])
    }

    func testEnrollWalksStagesToDone() {
        manager.enroll(slot: nil)
        XCTAssertEqual(h.sent.last, fpHex(String(format: "d0 21 %02x ff ff", h.lastReqId)))
        XCTAssertEqual(manager.activity, .enrolling(nil))
        let id = h.lastReqId
        reply("d0 a1 %02x 00")

        h.receive(String(format: "d0 70 %02x 00 01 01 00 05 00", id))
        XCTAssertEqual(manager.activity, .enrolling(BuddyEnrollProgress(stage: 1, sample: 0, slot: 5)))
        h.receive(String(format: "d0 70 %02x 00 01 03 01 05 00", id))
        h.receive(String(format: "d0 70 %02x 00 01 02 01 05 00", id))
        XCTAssertEqual(manager.activity, .enrolling(BuddyEnrollProgress(stage: 2, sample: 1, slot: 5)))
        h.receive(String(format: "d0 70 %02x 00 01 04 06 05 00", id))
        h.receive(String(format: "d0 70 %02x 00 01 05 06 05 00", id))

        XCTAssertEqual(manager.activity, .enrolled(slot: 5))
        XCTAssertTrue(h.sent.contains { $0[1] == 0x23 }, "the list refreshes after enrolling")
    }

    func testEnrollDuplicateFails() {
        manager.enroll(slot: nil)
        let id = h.lastReqId
        reply("d0 a1 %02x 00")
        h.receive(String(format: "d0 70 %02x 11 01 00 06 05 00", id))
        XCTAssertEqual(manager.activity, .failed(.duplicate))
        XCTAssertFalse(manager.isBusy)
    }

    func testVerifyReportsSlot() {
        manager.verify()
        let id = h.lastReqId
        reply("d0 a4 %02x 00")
        XCTAssertEqual(manager.activity, .verifying)
        h.receive(String(format: "d0 70 %02x 00 04 05 00", id))
        XCTAssertEqual(manager.activity, .matched(slot: 5))
    }

    func testVerifyNoMatch() {
        manager.verify()
        let id = h.lastReqId
        reply("d0 a4 %02x 00")
        h.receive(String(format: "d0 70 %02x 0f 04 ff ff", id))
        XCTAssertEqual(manager.activity, .failed(.noMatch))
    }

    func testDeleteRefreshesList() {
        manager.delete(slot: 5)
        XCTAssertEqual(h.sent.last, fpHex(String(format: "d0 25 %02x 05 00", h.lastReqId)))
        XCTAssertTrue(manager.isBusy)
        reply("d0 a5 %02x 00")
        XCTAssertEqual(manager.activity, .deleted(slot: 5))
        XCTAssertEqual(h.sent.last?[1], 0x23)
    }

    func testDeleteAllSendsFFFF() {
        manager.delete(slot: nil)
        XCTAssertEqual(h.sent.last, fpHex(String(format: "d0 25 %02x ff ff", h.lastReqId)))
    }

    func testBusyReplyShowsFailure() {
        manager.verify()
        reply("d0 a4 %02x 03")
        XCTAssertEqual(manager.activity, .failed(.busy))
    }

    func testNoReplyShowsFailureWithoutResult() {
        manager.verify()
        h.clock.fireNext()
        XCTAssertEqual(manager.activity, .failed(nil))
    }

    func testCancelDuringEnrollEndsCancelled() {
        manager.enroll(slot: nil)
        let id = h.lastReqId
        reply("d0 a1 %02x 00")
        manager.cancel()
        XCTAssertEqual(h.sent.last?[1], 0x22)
        h.receive(String(format: "d0 70 %02x 09 01 00 00 05 00", id))
        XCTAssertEqual(manager.activity, .failed(.cancelled))
    }

    func testDisconnectDuringEnrollFails() {
        manager.enroll(slot: nil)
        reply("d0 a1 %02x 00")
        h.channel.connectionDropped()
        XCTAssertEqual(manager.activity, .failed(nil))
        XCTAssertFalse(manager.isBusy)
    }
}
