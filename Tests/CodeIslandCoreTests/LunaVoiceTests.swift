import XCTest
@testable import CodeIslandCore

/// Luna's spoken cues follow the X10A Tab5's rules (luna-work app/notify/buddy_link.h, home_view showVoiceLine).
final class LunaVoiceTests: XCTestCase {
    private let lines = [
        LunaLine(id: "alert_1", group: "red", ja: "コンディションレッド発令！", zh: "发布红色状态！"),
        LunaLine(id: "alert_2", group: "red", ja: "総員、第一戦闘配備！", zh: "全员，第一战斗配置！"),
        LunaLine(id: "approve_1", group: "blue", ja: "艦長、敵機、高速で接近中！", zh: "舰长，敌机高速接近！"),
        LunaLine(id: "boot_1", group: "boot", ja: "ルナマリア・ホーク、ザク、出るわよ！", zh: "露娜玛丽亚·霍克，扎古，出击了！"),
    ]

    func testEventsMapToTheTab5Groups() {
        XCTAssertEqual(LunaVoiceRules.group(forEvent: "PermissionRequest"), "red")
        XCTAssertEqual(LunaVoiceRules.group(forEvent: EventSoundRouting.turnFailed), "red")
        XCTAssertEqual(LunaVoiceRules.group(forEvent: "Stop"), "blue")
        XCTAssertEqual(LunaVoiceRules.group(forEvent: "TaskRoundComplete"), "blue")
        XCTAssertNil(LunaVoiceRules.group(forEvent: "SessionStart"))  // starting work needs no voice
        XCTAssertNil(LunaVoiceRules.group(forEvent: "UserPromptSubmit"))
    }

    func testAPickNeverRepeatsTheLineJustSpokenAndAGroupWithoutLinesIsSkipped() {
        var q = LunaVoiceQueue()
        let now = Date()
        XCTAssertTrue(q.push("red", now: now))
        XCTAssertEqual(q.next(from: lines, random: { _ in 0 })?.id, "alert_1")
        XCTAssertTrue(q.push("red", now: now))
        XCTAssertEqual(q.next(from: lines, random: { _ in 0 })?.id, "alert_2")  // not alert_1 again
        XCTAssertTrue(q.push("lost", now: now))  // no line in this pack
        XCTAssertTrue(q.push("boot", now: now))
        XCTAssertEqual(q.next(from: lines, random: { _ in 0 })?.id, "boot_1")
        XCTAssertNil(q.next(from: lines, random: { _ in 0 }))
    }

    func testBlueIsDedupedAndTheQueueIsBounded() {
        var q = LunaVoiceQueue()
        let t = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(q.push("blue", now: t))
        XCTAssertFalse(q.push("blue", now: t.addingTimeInterval(1.5)))  // the same finish
        XCTAssertTrue(q.push("blue", now: t.addingTimeInterval(2.5)))
        XCTAssertTrue(q.push("red", now: t))
        XCTAssertFalse(q.push("red", now: t))  // at most three waiting
        XCTAssertEqual(q.queued, ["blue", "blue", "red"])
    }
}
