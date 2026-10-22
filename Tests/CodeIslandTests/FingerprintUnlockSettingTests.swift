import XCTest
@testable import CodeIsland

/// Phase-1 unlock has no real security, so it stays off until the user
/// turns it on in Settings.
@MainActor
final class FingerprintUnlockSettingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "FingerprintUnlockSettingTests")
        defaults.removePersistentDomain(forName: "FingerprintUnlockSettingTests")
        defaults.register(defaults: [SettingsKey.fingerprintUnlockEnabled: SettingsDefaults.fingerprintUnlockEnabled])
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "FingerprintUnlockSettingTests")
        defaults = nil
        try await super.tearDown()
    }

    func testDefaultIsOff() {
        XCTAssertFalse(SettingsDefaults.fingerprintUnlockEnabled)
        XCTAssertFalse(LiveFingerprintUnlockSystem(defaults: defaults).isEnabled)
    }

    func testTurningItOnIsSeen() {
        defaults.set(true, forKey: SettingsKey.fingerprintUnlockEnabled)
        XCTAssertTrue(LiveFingerprintUnlockSystem(defaults: defaults).isEnabled)
    }
}
