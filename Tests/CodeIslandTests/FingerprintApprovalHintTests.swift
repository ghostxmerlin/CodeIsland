import XCTest
@testable import CodeIsland
import CodeIslandCore

final class FingerprintApprovalHintTests: XCTestCase {
    private func status(present: Bool, count: Int?) -> BuddyFingerprintStatus {
        BuddyFingerprintStatus(version: 1, present: present, count: count, hasAttest: true, activeOp: 0)
    }

    func testEnrolledSensorMeansPressOnAtom() {
        XCTAssertEqual(FingerprintApprovalHint.resolve([status(present: true, count: 2)]), .pressFingerOnAtom)
    }

    func testNoEnrolledFingerMeansApproveOnMac() {
        XCTAssertEqual(FingerprintApprovalHint.resolve([status(present: true, count: 0)]), .approveOnMac)
        XCTAssertEqual(FingerprintApprovalHint.resolve([status(present: true, count: nil)]), .approveOnMac)
    }

    func testMissingSensorMeansApproveOnMac() {
        XCTAssertEqual(FingerprintApprovalHint.resolve([status(present: false, count: 3)]), .approveOnMac)
        XCTAssertEqual(FingerprintApprovalHint.resolve([nil]), .approveOnMac)
    }

    func testAnyReadyAtomWins() {
        XCTAssertEqual(FingerprintApprovalHint.resolve([status(present: false, count: 0),
                                                        status(present: true, count: 1)]), .pressFingerOnAtom)
    }

    func testNoFingerprintBuddyKeepsTheOldUI() {
        XCTAssertNil(FingerprintApprovalHint.resolve([]))
    }
}
