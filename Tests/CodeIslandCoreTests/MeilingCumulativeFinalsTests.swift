import XCTest
@testable import CodeIslandCore

/// transcribe-live finals became cumulative on 2026-11-18: each one repeats the whole session so far, sometimes with
/// earlier words revised. Only what is new may be typed.
final class MeilingCumulativeFinalsTests: XCTestCase {
    func testFirstFinalIsTypedWhole() {
        var finals = MeilingCumulativeFinals()
        XCTAssertEqual(finals.fresh(in: "今天天气不错，我们去公园散步吧。"), "今天天气不错，我们去公园散步吧。")
    }

    /// The server's own sequence for three sentences (CLI run, 2026-11-18).
    func testCumulativeFinalsGiveOnlyTheNewSentence() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "今天天气不错，我们去公园散步吧。")
        XCTAssertEqual(finals.fresh(in: "今天天气不错，我们去公园散步吧。晚上我想吃火锅，你觉得怎么样？"),
                       "晚上我想吃火锅，你觉得怎么样？")
        XCTAssertEqual(finals.fresh(in: "今天天气不错，我们去公园散步吧。晚上我想吃火锅，你觉得怎么样？明天记得把报告发给我。"),
                       "明天记得把报告发给我。")
    }

    func testARepeatedFinalGivesNothing() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "明天记得把报告发给我。")
        XCTAssertEqual(finals.fresh(in: "明天记得把报告发给我。"), "")
    }

    /// Earlier words rewritten, nothing added: what was typed stays, nothing is typed again.
    func testARevisionOfEarlierTextGivesNothing() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "我说了Hello之后，模块会打一句I'm here。这个I'm here有时候会干扰到。")
        XCTAssertEqual(finals.fresh(in: "我说了Hello之后，模块会打一句I'm here。这个译音有时候会干扰到。"), "")
    }

    func testARevisionWithANewSentenceGivesTheNewSentence() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "我刚才有做了一个。预想，设想。你后来做了吗？")
        XCTAssertEqual(finals.fresh(in: "我刚才有做了一个预想。你后来做了吗？还是怎么规划的？"), "还是怎么规划的？")
    }

    func testARevisedEndingStillFindsTheNewSentence() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "你是每分钟到时间之后一起送进去理解的吗")
        XCTAssertEqual(finals.fresh(in: "你是每分钟到时间之后一起送进去理解的吗？这样好像会很慢。"), "？这样好像会很慢。")
    }

    /// Should the server go back to one sentence per final, each is typed whole.
    func testUnrelatedFinalsAreTypedWhole() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "今天天气不错，我们去公园散步吧。")
        XCTAssertEqual(finals.fresh(in: "晚上我想吃火锅，你觉得怎么样？"), "晚上我想吃火锅，你觉得怎么样？")
        XCTAssertEqual(finals.fresh(in: "好的。"), "好的。")
    }

    /// A new connection starts from nothing, even when it opens with the same words.
    func testResetForgetsTheSession() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "好的。")
        finals.reset()
        XCTAssertEqual(finals.fresh(in: "好的，我们开始吧。"), "好的，我们开始吧。")
    }

    func testLatinWordsKeepNoLeadingSpace() {
        var finals = MeilingCumulativeFinals()
        _ = finals.fresh(in: "Open the pod bay doors.")
        XCTAssertEqual(finals.fresh(in: "Open the pod bay doors. I'm sorry Dave."), "I'm sorry Dave.")
    }
}
