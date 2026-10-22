import XCTest
@testable import CodeIsland

final class FingerprintUnlockGateTests: XCTestCase {
    func testInactiveGateWaits() {
        var gate = FingerprintUnlockGate()
        XCTAssertEqual(gate.step(locked: true, verified: true), .wait)
    }

    func testChallengesOnceAfterLockThenFiresWhenVerified() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        XCTAssertEqual(gate.step(locked: true, verified: false), .challenge)
        XCTAssertEqual(gate.step(locked: true, verified: false), .wait)
        XCTAssertEqual(gate.step(locked: true, verified: true), .fire)
        XCTAssertFalse(gate.active)
        XCTAssertEqual(gate.step(locked: true, verified: true), .wait)
    }

    func testWaitsWhileNotYetLocked() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        XCTAssertEqual(gate.step(locked: false, verified: false), .wait)
        XCTAssertTrue(gate.active)
    }

    func testUnlockAfterLockStops() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        _ = gate.step(locked: true, verified: false)
        XCTAssertEqual(gate.step(locked: false, verified: true), .stop)
        XCTAssertFalse(gate.active)
    }

    func testUnknownLockStateStops() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        XCTAssertEqual(gate.step(locked: nil, verified: true), .stop)
    }

    func testFailEndsTheRound() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        _ = gate.step(locked: true, verified: false)
        gate.fail()
        XCTAssertEqual(gate.step(locked: true, verified: true), .wait)
    }

    func testNoDeadline() {
        var gate = FingerprintUnlockGate()
        gate.arm()
        XCTAssertEqual(gate.step(locked: true, verified: false), .challenge)
        for _ in 0..<2400 { XCTAssertEqual(gate.step(locked: true, verified: false), .wait) } // 10 min of 0.25 s ticks
        XCTAssertTrue(gate.active)
    }
}
