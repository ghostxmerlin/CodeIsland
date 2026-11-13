import XCTest
@testable import CodeIsland

/// Meyrin's two keys (2026-11-13): the talk key dictates as said, the translate key into English. They never
/// resolve to the same key.
@MainActor
final class MeilingSoftKeysTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "MeilingSoftKeysTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func key(_ slot: MeilingSoftHotkey.Slot) -> String { MeilingSoftHotkey.key(slot, defaults: defaults).name }

    func testDefaultsAreRightCommandAndRightOption() {
        XCTAssertEqual(key(.talk), "Right ⌘")
        XCTAssertEqual(key(.translate), "Right ⌥")
    }

    func testTheTalkKeyKeepsItsStoredKey() {
        defaults.set(122, forKey: MeilingSoftHotkey.Slot.talk.defaultsKey)  // F1
        XCTAssertEqual(key(.talk), "F1")
        XCTAssertEqual(key(.translate), "Right ⌥")
        XCTAssertEqual(MeilingSoftHotkey.keyDefault, "meilingSoftTalkKey")  // the key recorded before 2026-11-13
    }

    func testADefaultTranslateKeyStepsAsideForTheTalkKey() {
        defaults.set(61, forKey: MeilingSoftHotkey.Slot.talk.defaultsKey)  // right ⌥
        XCTAssertEqual(key(.talk), "Right ⌥")
        XCTAssertEqual(key(.translate), "Right ⌘")
    }

    func testAStoredTranslateKeyIsUsed() {
        defaults.set(63, forKey: MeilingSoftHotkey.Slot.translate.defaultsKey)  // fn
        XCTAssertEqual(key(.translate), "fn")
    }

    func testAClashingStoredTranslateKeyFallsBack() {
        defaults.set(63, forKey: MeilingSoftHotkey.Slot.talk.defaultsKey)
        defaults.set(63, forKey: MeilingSoftHotkey.Slot.translate.defaultsKey)
        XCTAssertEqual(key(.talk), "fn")
        XCTAssertEqual(key(.translate), "Right ⌥")
    }

    func testAnUnknownStoredCodeFallsBackToTheDefault() {
        defaults.set(0, forKey: MeilingSoftHotkey.Slot.translate.defaultsKey)  // "A": would also type
        XCTAssertEqual(key(.translate), "Right ⌥")
    }

    func testSlotsNameEachOther() {
        XCTAssertEqual(MeilingSoftHotkey.Slot.talk.other, .translate)
        XCTAssertEqual(MeilingSoftHotkey.Slot.translate.label, "Translate Key")
    }
}
