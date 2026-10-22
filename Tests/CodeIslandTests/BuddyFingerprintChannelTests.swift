import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class BuddyFingerprintChannelTests: XCTestCase {
    private var h: FingerprintChannelHarness!

    override func setUp() async throws {
        try await super.setUp()
        h = FingerprintChannelHarness()
    }

    func testProbeRetriesOnceThenMarksUnsupported() {
        h.channel.start()
        XCTAssertEqual(h.channel.support, .probing)
        XCTAssertEqual(h.clock.pendingDelays, [5])

        h.clock.fireNext()
        XCTAssertEqual(h.channel.support, .probing)
        h.clock.fireNext()

        XCTAssertEqual(h.channel.support, .unsupported)
        XCTAssertEqual(h.sent.map { Array($0.prefix(2)) }, [[0xD0, 0x01], [0xD0, 0x01]])
    }

    func testProbeSuccessThenAttestMatches() {
        h.channel.start()
        h.receive("d0 81 01 00 01 01 05 01 00")
        XCTAssertEqual(h.channel.support, .supported)
        XCTAssertEqual(h.channel.status?.count, 5)
        XCTAssertEqual(h.sent.last, fpHex("d0 42 02"))

        h.receive("d0 c2 02 00 01 01 d9 df b1 6e ad 4e f7 db")
        XCTAssertTrue(h.channel.keyMatches)
        XCTAssertTrue(h.channel.canUnlock)
    }

    func testProbeAnsweredOnRetryIsSupported() {
        h.channel.start()
        h.clock.fireNext()
        h.receive(String(format: "d0 81 %02x 00 01 01 05 01 00", h.lastReqId))
        XCTAssertEqual(h.channel.support, .supported)
    }

    func testAttestMismatchBlocksUnlock() {
        h.channel.start()
        h.receive("d0 81 01 00 01 01 05 01 00")
        h.receive("d0 c2 02 00 01 01 00 11 22 33 44 55 66 77")
        XCTAssertFalse(h.channel.keyMatches)
        XCTAssertFalse(h.channel.canUnlock)
    }

    func testNoEnrolledFingerBlocksUnlock() {
        h.channel.start()
        h.receive("d0 81 01 00 01 01 00 01 00")
        h.receive("d0 c2 02 00 01 00 d9 df b1 6e ad 4e f7 db")
        XCTAssertTrue(h.channel.keyMatches)
        XCTAssertFalse(h.channel.canUnlock)
    }

    func testUnsupportedChannelSendsNothing() {
        h.channel.start()
        h.clock.fireNext()
        h.clock.fireNext()
        h.sent.removeAll()

        var result: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { result = $0 }

        XCTAssertEqual(result.map(Self.describe), "failure(unsupported)")
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testOnlyOneRequestInFlight() {
        h.startSupported()
        var listResult: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { listResult = $0 }
        h.channel.request(.verify) { _ in }
        XCTAssertEqual(h.sent.count, 1)

        let listId = h.lastReqId
        h.receive(String(format: "d0 a3 %02x 00 1f 00 00 00 00 00 00 00 00 00 00 00 00", listId))
        XCTAssertEqual(try listResult?.get().payload.first, 0x1F)
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent.last?[1], 0x24)
    }

    func testCancelBypassesQueue() {
        h.startSupported()
        h.channel.request(.list) { _ in }
        h.channel.cancel()
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent.last?[1], 0x22)
    }

    func testReqIdWrapsTo1() {
        h.startSupported()
        var ids: [UInt8] = []
        for _ in 0..<256 {
            h.channel.cancel()
            ids.append(h.lastReqId)
        }
        XCTAssertFalse(ids.contains(0))
        XCTAssertEqual(ids.firstIndex(of: 255).map { ids[$0 + 1] }, 1)
    }

    func testUnknownReqIdIgnored() {
        h.startSupported()
        var result: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { result = $0 }
        h.receive(String(format: "d0 a3 %02x 00 1f", h.lastReqId &+ 7))
        XCTAssertNil(result)
    }

    func testRepliesRouteToTheRequestAndEventsToItsHandler() {
        h.startSupported()
        var events: [BuddyFingerprintEvent] = []
        var reply: BuddyFingerprintReply?
        h.channel.request(.verify, onEvent: { events.append(try! $0.get()) }) { reply = try? $0.get() }
        let id = h.lastReqId
        h.receive(String(format: "d0 a4 %02x 00", id))
        h.receive(String(format: "d0 70 %02x 00 04 05 00", id))

        XCTAssertEqual(reply?.result, .ok)
        XCTAssertEqual(events.map(\.kind), [.verify])
    }

    func testStaleEventDoesNotReachNewOperation() {
        h.startSupported()
        var firstEvents = 0
        h.channel.request(.verify, onEvent: { _ in firstEvents += 1 }) { _ in }
        let firstId = h.lastReqId
        h.receive(String(format: "d0 a4 %02x 00", firstId))
        h.receive(String(format: "d0 70 %02x 09 04 ff ff", firstId))   // Cancelled ends it

        var secondEvents: [BuddyFingerprintEvent] = []
        h.channel.request(.verify, onEvent: { secondEvents.append(try! $0.get()) }) { _ in }
        h.receive(String(format: "d0 a4 %02x 00", h.lastReqId))
        h.receive(String(format: "d0 70 %02x 09 04 ff ff", firstId))   // late duplicate for the old id

        XCTAssertEqual(firstEvents, 1)
        XCTAssertTrue(secondEvents.isEmpty)
    }

    func testDisconnectFailsPendingAndEndsOperations() {
        h.startSupported()
        var enrollEnd: BuddyFingerprintError?
        h.channel.request(.enrollBegin, payload: BuddyFingerprintRequest.slotPayload(nil),
                          onEvent: { if case .failure(let e) = $0 { enrollEnd = e } }) { _ in }
        h.receive(String(format: "d0 a1 %02x 00", h.lastReqId))
        var listResult: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { listResult = $0 }

        h.channel.connectionDropped()

        XCTAssertEqual(listResult.map(Self.describe), "failure(disconnected)")
        XCTAssertEqual(enrollEnd, .disconnected)
        XCTAssertEqual(h.clock.pendingDelays, [])
    }

    func testUnlockSendsBothChunksWithSameReqId() {
        h.startSupported()
        let nonce = fpHex("55eb4843d3598a39d141d7d1f5e3256f 9474b60fc09492010a40b780dd661445")
        var started: Result<UInt8, BuddyFingerprintError>?
        h.channel.startUnlock(nonce: nonce, onEvent: { _ in }) { started = $0 }
        XCTAssertEqual(h.sent.count, 1)
        let id = h.lastReqId
        XCTAssertEqual(h.sent[0], BuddyFingerprintRequest.unlockChallengeFrames(reqId: id, nonce: nonce)[0])

        h.receive(String(format: "d0 c3 %02x 00 10", id))
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent[1], BuddyFingerprintRequest.unlockChallengeFrames(reqId: id, nonce: nonce)[1])
        XCTAssertNil(started)

        h.receive(String(format: "d0 c3 %02x 00", id))
        XCTAssertEqual(try started?.get(), id)
    }

    func testUnlockRejectedOnSecondChunk() {
        h.startSupported()
        var started: Result<UInt8, BuddyFingerprintError>?
        h.channel.startUnlock(nonce: BuddyFingerprintAttestation.makeNonce(), onEvent: { _ in }) { started = $0 }
        let id = h.lastReqId
        h.receive(String(format: "d0 c3 %02x 00 10", id))
        h.receive(String(format: "d0 c3 %02x 10", id))
        XCTAssertEqual(started.map(Self.describe), "failure(rejected(CodeIslandCore.BuddyFingerprintResult.noBinding))")
    }

    func testRequestTimesOutAfter8s() {
        h.startSupported()
        var result: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { result = $0 }
        XCTAssertEqual(h.clock.pendingDelays, [8])
        h.clock.fireNext()
        XCTAssertEqual(result.map(Self.describe), "failure(timeout)")
    }

    func testTimedOutRequestLetsTheNextOneGo() {
        h.startSupported()
        h.channel.request(.list) { _ in }
        h.channel.request(.verify) { _ in }
        h.clock.fireNext()
        XCTAssertEqual(h.sent.map { $0[1] }, [0x23, 0x24])
    }

    func testRejectedReplyIsAFailure() {
        h.startSupported()
        var result: Result<BuddyFingerprintReply, BuddyFingerprintError>?
        h.channel.request(.list) { result = $0 }
        h.receive(String(format: "d0 a3 %02x 03", h.lastReqId))
        XCTAssertEqual(result.map(Self.describe), "failure(rejected(CodeIslandCore.BuddyFingerprintResult.busy))")
    }

    private static func describe<T>(_ result: Result<T, BuddyFingerprintError>) -> String {
        switch result {
        case .success: return "success"
        case .failure(let error): return "failure(\(error))"
        }
    }
}
