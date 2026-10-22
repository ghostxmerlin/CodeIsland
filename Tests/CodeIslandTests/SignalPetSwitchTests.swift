import XCTest
@testable import CodeIsland

/// Settings → General → Desktop Pet shows or hides the signal-cat while the
/// app runs; it is on unless the user turned it off.
@MainActor
final class SignalPetSwitchTests: XCTestCase {
    private final class FakePet: SignalPetPresenting {
        var shown = false
        func show() { shown = true }
        func hide() { shown = false }
    }

    private var defaults: UserDefaults!
    private var made: [FakePet] = []

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "SignalPetSwitchTests")
        defaults.removePersistentDomain(forName: "SignalPetSwitchTests")
        defaults.register(defaults: [SettingsKey.showSignalPet: SettingsDefaults.showSignalPet])
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "SignalPetSwitchTests")
        defaults = nil
        try await super.tearDown()
    }

    private func makeSwitch() -> SignalPetSwitch {
        SignalPetSwitch(defaults: defaults) { [unowned self] in
            let pet = FakePet()
            made.append(pet)
            return pet
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testPetIsOnByDefault() {
        XCTAssertTrue(SettingsDefaults.showSignalPet)
        let toggle = makeSwitch()
        toggle.start()
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(made[0].shown)
    }

    func testTurnedOffAtLaunchShowsNothing() {
        defaults.set(false, forKey: SettingsKey.showSignalPet)
        makeSwitch().start()
        XCTAssertTrue(made.isEmpty)
    }

    func testTogglingWhileRunningHidesAndBringsThePetBack() async {
        let toggle = makeSwitch()
        toggle.start()

        defaults.set(false, forKey: SettingsKey.showSignalPet)
        await settle()
        XCTAssertFalse(made[0].shown)

        defaults.set(true, forKey: SettingsKey.showSignalPet)
        await settle()
        XCTAssertEqual(made.count, 2, "a fresh pet resolves the current lamp")
        XCTAssertTrue(made[1].shown)
        _ = toggle
    }
}
