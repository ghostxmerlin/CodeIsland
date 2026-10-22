import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
private final class FakeSystem: FingerprintUnlockSystem {
    var isEnabled = true
    var isAccessibilityTrusted = true
    var locked: Bool? = false
    var password: Data? = Data("hunter2".utf8)
    var typeError: Error?
    var typed: [Data] = []
    var clock: TimeInterval = 0

    func lockState() -> Bool? { locked }
    func hasPassword() -> Bool { password != nil }
    func readPassword() throws -> Data {
        guard let password else { throw UnlockPasswordStoreError.missing }
        return password
    }
    func typePassword(_ password: Data) throws {
        if let typeError { throw typeError }
        typed.append(password)
    }
    func now() -> TimeInterval { clock }
}

@MainActor
private final class FakeDevice: FingerprintUnlockDevice {
    let id = UUID()
    var canUnlock = true
    var nonces: [Data] = []
    var cancels = 0
    private var onEvent: BuddyFingerprintChannel.EventHandler?
    private var completion: ((Result<UInt8, BuddyFingerprintError>) -> Void)?

    func startUnlock(nonce: Data, onEvent: @escaping BuddyFingerprintChannel.EventHandler,
                     completion: @escaping (Result<UInt8, BuddyFingerprintError>) -> Void) {
        nonces.append(nonce)
        self.onEvent = onEvent
        self.completion = completion
    }

    func cancel() { cancels += 1 }

    func accept() { completion?(.success(UInt8(nonces.count))) }
    func refuse(_ error: BuddyFingerprintError) { completion?(.failure(error)) }

    func event(_ result: BuddyFingerprintResult, data: Data = Data()) {
        onEvent?(.success(BuddyFingerprintEvent(reqId: UInt8(nonces.count), result: result, kind: .unlock, data: data)))
    }

    func validTag() { event(.ok, data: BuddyFingerprintAttestation.tag(nonce: nonces.last!)) }
    func drop() { onEvent?(.failure(.disconnected)) }
}

@MainActor
final class FingerprintUnlockControllerTests: XCTestCase {
    private var system: FakeSystem!
    private var device: FakeDevice!
    private var available = true
    private var controller: FingerprintUnlockController!

    override func setUp() async throws {
        try await super.setUp()
        system = FakeSystem()
        device = FakeDevice()
        available = true
        controller = FingerprintUnlockController(system: system) { [unowned self] in available ? device : nil }
    }

    /// Lock the screen and get Atom waiting for a finger.
    private func lockAndChallenge() {
        system.locked = true
        controller.tick()
        device.accept()
    }

    func testArmsOncePerLock() {
        lockAndChallenge()
        controller.tick()
        controller.tick()
        XCTAssertEqual(device.nonces.count, 1)
        XCTAssertEqual(device.nonces[0].count, 32)
        XCTAssertEqual(controller.phase, .waitingForFinger(noMatch: false))

        system.locked = false
        controller.tick()
        lockAndChallenge()
        XCTAssertEqual(device.nonces.count, 2)
        XCTAssertNotEqual(device.nonces[0], device.nonces[1])
    }

    func testPreconditionMissDoesNotLatch() {
        system.isAccessibilityTrusted = false
        system.locked = true
        controller.tick()
        XCTAssertTrue(device.nonces.isEmpty)

        system.isAccessibilityTrusted = true
        controller.tick()
        XCTAssertEqual(device.nonces.count, 1)
    }

    func testMissingPasswordOrDeviceDoesNotArm() {
        system.password = nil
        system.locked = true
        controller.tick()
        device.canUnlock = false
        system.password = Data("pw".utf8)
        controller.tick()
        available = false
        controller.tick()
        XCTAssertTrue(device.nonces.isEmpty)
    }

    func testNoMatchKeepsRoundAndNonce() {
        lockAndChallenge()
        device.event(.noMatch)
        controller.tick()
        XCTAssertEqual(controller.phase, .waitingForFinger(noMatch: true))
        XCTAssertEqual(device.nonces.count, 1)
        XCTAssertEqual(device.cancels, 0)

        device.validTag()
        XCTAssertEqual(system.typed.count, 1)
    }

    func testValidTagTypesOnce() {
        lockAndChallenge()
        device.validTag()
        XCTAssertEqual(system.typed, [Data("hunter2".utf8)])
        XCTAssertEqual(controller.phase, .submitting)

        system.clock = 8.5
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.phase, .stopped(.notConfirmed))
        XCTAssertEqual(system.typed.count, 1)
        XCTAssertEqual(device.nonces.count, 1, "no retry while still locked")
    }

    func testConfirmedUnlockEndsInUnlocked() {
        lockAndChallenge()
        device.validTag()
        system.clock = 2
        system.locked = false
        controller.tick()
        XCTAssertEqual(controller.phase, .unlocked)
    }

    func testInvalidTagNeverTypes() {
        lockAndChallenge()
        var tag = BuddyFingerprintAttestation.tag(nonce: device.nonces[0])
        tag[tag.startIndex] ^= 0x01
        device.event(.ok, data: tag)
        controller.tick()
        XCTAssertTrue(system.typed.isEmpty)
        XCTAssertEqual(controller.phase, .stopped(.tagInvalid))
    }

    func testTagForAnotherNonceNeverTypes() {
        lockAndChallenge()
        device.event(.ok, data: BuddyFingerprintAttestation.tag(nonce: BuddyFingerprintAttestation.makeNonce()))
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testTagWhileUnlockedNeverTypes() {
        lockAndChallenge()
        system.locked = false
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
        XCTAssertEqual(controller.phase, .stopped(.unlockedElsewhere))
    }

    func testUnlockedElsewhereCancelsTheRound() {
        lockAndChallenge()
        system.locked = false
        controller.tick()
        XCTAssertEqual(device.cancels, 1)
        XCTAssertEqual(controller.phase, .stopped(.unlockedElsewhere))
    }

    func testUnknownLockStateStops() {
        lockAndChallenge()
        system.locked = nil
        controller.tick()
        XCTAssertEqual(device.cancels, 1)
        XCTAssertEqual(controller.phase, .stopped(.lockStateUnknown))
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testPasswordReadFailureNeverTypes() {
        lockAndChallenge()
        system.password = nil
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
        XCTAssertEqual(controller.phase, .stopped(.passwordUnavailable))
    }

    func testTypingRefusalStopsWithoutRetry() {
        lockAndChallenge()
        system.typeError = LockScreenRefusal.noVisibleWindow
        device.validTag()
        controller.tick()
        XCTAssertEqual(controller.phase, .stopped(.typingRefused(.noVisibleWindow)))
        XCTAssertEqual(device.nonces.count, 1)
    }

    func testStaleEventFromPreviousRoundIgnored() {
        lockAndChallenge()
        let oldTag = BuddyFingerprintAttestation.tag(nonce: device.nonces[0])
        controller.screenDidWake()                  // ends round 1
        controller.tick()
        device.accept()
        XCTAssertEqual(device.nonces.count, 2)

        // Round 1's answer shows up late through round 2's handler.
        device.event(.ok, data: oldTag)
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testReconnectEndsRoundAndAllowsNewNonce() {
        lockAndChallenge()
        device.drop()
        XCTAssertEqual(controller.phase, .stopped(.deviceLost))
        controller.tick()
        XCTAssertEqual(device.nonces.count, 1)

        controller.deviceDidReconnect()
        controller.tick()
        XCTAssertEqual(device.nonces.count, 2)
        XCTAssertNotEqual(device.nonces[0], device.nonces[1])
    }

    func testChallengeRefusedEndsRound() {
        system.locked = true
        controller.tick()
        device.refuse(.rejected(.noBinding))
        XCTAssertEqual(controller.phase, .stopped(.fingerprintFailed(.noBinding)))
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testSleepCancels() {
        lockAndChallenge()
        controller.systemWillSleep()
        XCTAssertEqual(device.cancels, 1)
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testSettingOffCancels() {
        lockAndChallenge()
        system.isEnabled = false
        controller.settingDidTurnOff()
        XCTAssertEqual(device.cancels, 1)
        device.validTag()
        controller.tick()
        XCTAssertTrue(system.typed.isEmpty)
    }

    func testDisabledNeverArms() {
        system.isEnabled = false
        system.locked = true
        controller.tick()
        XCTAssertTrue(device.nonces.isEmpty)
    }

    func testOtherErrorEndsRound() {
        lockAndChallenge()
        device.event(.sensorError)
        XCTAssertEqual(controller.phase, .stopped(.fingerprintFailed(.sensorError)))
        XCTAssertEqual(device.cancels, 0, "Atom already ended this round")
        device.validTag()
        XCTAssertTrue(system.typed.isEmpty)
    }
}
