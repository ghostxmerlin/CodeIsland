import XCTest
@testable import CodeIsland

final class ESP32BridgeMultiBuddyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ESP32BridgeMultiBuddyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Selection persistence

    func testSelectionRoundTripsSeveralBuddiesInOrder() {
        let first = BuddySelection(id: UUID(), name: "Buddy-AAAAAA")
        let second = BuddySelection(id: UUID(), name: nil)

        BuddySelectionStore.save([first, second], to: defaults)

        XCTAssertEqual(BuddySelectionStore.load(from: defaults), [first, second])
    }

    func testSelectionMigratesTheLegacySingleBuddyKeys() {
        let id = UUID()
        defaults.set(id.uuidString, forKey: SettingsKey.selectedBuddyIdentifier)
        defaults.set("Buddy-123456", forKey: SettingsKey.selectedBuddyName)

        XCTAssertEqual(BuddySelectionStore.load(from: defaults),
                       [BuddySelection(id: id, name: "Buddy-123456")])
    }

    func testSelectionIgnoresAnEmptyLegacyIdentifier() {
        defaults.set("", forKey: SettingsKey.selectedBuddyIdentifier)

        XCTAssertEqual(BuddySelectionStore.load(from: defaults), [])
    }

    func testSavedListWinsOverLegacyKeysEvenWhenEmpty() {
        defaults.set(UUID().uuidString, forKey: SettingsKey.selectedBuddyIdentifier)

        BuddySelectionStore.save([], to: defaults)

        XCTAssertEqual(BuddySelectionStore.load(from: defaults), [])
    }

    func testSelectionDropsDuplicateAndMalformedEntries() {
        let id = UUID()
        defaults.set([
            ["id": id.uuidString, "name": "Buddy-1"],
            ["id": id.uuidString, "name": "Buddy-1 again"],
            ["id": "not-a-uuid"],
            ["name": "no id"],
        ], forKey: SettingsKey.selectedBuddies)

        XCTAssertEqual(BuddySelectionStore.load(from: defaults),
                       [BuddySelection(id: id, name: "Buddy-1")])
    }

    func testSaveMirrorsTheFirstBuddyIntoLegacyKeys() {
        let first = BuddySelection(id: UUID(), name: "Buddy-1")
        BuddySelectionStore.save([first, BuddySelection(id: UUID(), name: "Buddy-2")], to: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKey.selectedBuddyIdentifier), first.id.uuidString)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.selectedBuddyName), "Buddy-1")

        BuddySelectionStore.save([], to: defaults)

        // Registered app defaults may surface "" once the keys are removed.
        XCTAssertEqual(defaults.string(forKey: SettingsKey.selectedBuddyIdentifier) ?? "", "")
        XCTAssertEqual(defaults.string(forKey: SettingsKey.selectedBuddyName) ?? "", "")
    }

    // MARK: - Status aggregation

    func testAggregateIsNilWithoutLinks() {
        XCTAssertNil(ESP32BridgeStatus.aggregate([]))
    }

    func testOneConnectedBuddyMakesTheBridgeConnected() {
        XCTAssertEqual(ESP32BridgeStatus.aggregate([.reconnecting(4), .connected, .pairRejected]), .connected)
    }

    func testAggregatePrefersTheMostAdvancedHandshake() {
        XCTAssertEqual(ESP32BridgeStatus.aggregate([.searchingSelected, .pairWaitingConfirm, .connecting]),
                       .pairWaitingConfirm)
    }

    func testAggregatePicksTheSoonestReconnect() {
        XCTAssertEqual(ESP32BridgeStatus.aggregate([.reconnecting(8), .reconnecting(2), .pairRejected]),
                       .reconnecting(2))
    }
}
