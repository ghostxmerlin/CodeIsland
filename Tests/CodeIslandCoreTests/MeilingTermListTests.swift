import XCTest
@testable import CodeIslandCore

/// The vocabulary list behind Settings → Meyrin → Vocabulary (meiling-terms.json).
final class MeilingTermListTests: XCTestCase {
    func testANewTermLeadsTheList() {
        var list = MeilingTermList(["Tab5", "美玲"])
        XCTAssertTrue(list.add("  Meyrin "))
        XCTAssertEqual(list.terms, ["Meyrin", "Tab5", "美玲"])
    }

    func testAnEmptyOrKnownTermIsNotAdded() {
        var list = MeilingTermList(["Tab5", "美玲"])
        XCTAssertFalse(list.add("   "))
        XCTAssertFalse(list.add("tab5"))  // the vocabulary ignores case
        XCTAssertEqual(list.terms, ["Tab5", "美玲"])
    }

    func testRenameKeepsThePlace() {
        var list = MeilingTermList(["Tab5", "烧录", "美玲"])
        XCTAssertTrue(list.rename("烧录", to: " 烧写 "))
        XCTAssertEqual(list.terms, ["Tab5", "烧写", "美玲"])
    }

    func testRenameToAnotherTermOrToNothingIsRefused() {
        var list = MeilingTermList(["Tab5", "烧录", "美玲"])
        XCTAssertFalse(list.rename("烧录", to: "TAB5"))
        XCTAssertFalse(list.rename("烧录", to: ""))
        XCTAssertFalse(list.rename("没有", to: "有"))
        XCTAssertEqual(list.terms, ["Tab5", "烧录", "美玲"])
    }

    func testRenameMayChangeOnlyTheCase() {
        var list = MeilingTermList(["aism"])
        XCTAssertTrue(list.rename("aism", to: "AISM"))
        XCTAssertEqual(list.terms, ["AISM"])
    }

    func testRemove() {
        var list = MeilingTermList(["Tab5", "烧录", "美玲"])
        list.remove("烧录")
        XCTAssertEqual(list.terms, ["Tab5", "美玲"])
    }

    /// Corrected words come first and count against the limit, so the end of a long list is not sent.
    func testTermsPastTheLimitAreNotInUse() {
        let list = MeilingTermList(["Tab5", "听写", "美玲", "aism"])
        let corrections = [MeilingCorrection(heard: "听悟", right: "听写"), MeilingCorrection(heard: "地板", right: "底板")]
        XCTAssertEqual(list.inUse(corrections: corrections, limit: 4), ["Tab5", "听写", "美玲"])
    }

    func testTheFileIsAPlainArrayThatReadsBack() {
        let list = MeilingTermList(["Tab5", "美玲", "Unit 2Relay"])
        XCTAssertEqual(MeilingSoftFiles.terms(from: list.fileData()), ["Tab5", "美玲", "Unit 2Relay"])
        XCTAssertTrue(String(decoding: list.fileData(), as: UTF8.self).contains("美玲"))  // readable, not \u escapes
    }
}
