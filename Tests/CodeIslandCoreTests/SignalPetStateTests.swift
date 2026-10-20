import XCTest
@testable import CodeIslandCore

/// The desktop signal-cat shows one lamp for all sessions at once:
/// red = an agent stopped mid-task and needs the user (approval, question, error),
/// blue = an agent finished a turn the user has not looked at yet,
/// green = no agents, every agent is busy, or finished turns were already seen.
final class SignalPetStateTests: XCTestCase {
    private func session(_ status: AgentStatus, failed: Bool = false, unseen: Bool = false) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.status = status
        s.lastTurnFailed = failed
        s.completionUnseen = unseen
        return s
    }

    // MARK: - Resolving the lamp

    func testNoSessionsIsGreen() {
        XCTAssertEqual(SignalPetState.resolve([]), .working)
        XCTAssertEqual(SignalPetState.working.lamp, .green)
    }

    func testAllBusySessionsAreGreen() {
        XCTAssertEqual(SignalPetState.resolve([session(.processing), session(.running)]), .working)
    }

    func testUnseenFinishedTurnIsBlue() {
        XCTAssertEqual(SignalPetState.resolve([session(.running), session(.idle, unseen: true)]), .awaitingInput)
        XCTAssertEqual(SignalPetState.awaitingInput.lamp, .blue)
    }

    func testFinishedTurnAlreadySeenIsGreen() {
        XCTAssertEqual(SignalPetState.resolve([session(.running), session(.idle), session(.idle)]), .working)
    }

    func testApprovalOrQuestionIsRed() {
        XCTAssertEqual(SignalPetState.resolve([session(.idle), session(.waitingApproval)]), .needsAttention)
        XCTAssertEqual(SignalPetState.resolve([session(.waitingQuestion)]), .needsAttention)
        XCTAssertEqual(SignalPetState.needsAttention.lamp, .red)
    }

    func testUnseenFailedTurnIsRedEvenThoughStatusIsIdle() {
        XCTAssertEqual(SignalPetState.resolve([session(.idle, failed: true, unseen: true), session(.idle, unseen: true)]), .failed)
        XCTAssertEqual(SignalPetState.failed.lamp, .red)
    }

    func testFailedTurnAlreadySeenIsGreen() {
        XCTAssertEqual(SignalPetState.resolve([session(.idle, failed: true)]), .working)
    }

    func testPendingRequestOutranksFailure() {
        XCTAssertEqual(
            SignalPetState.resolve([session(.idle, failed: true, unseen: true), session(.waitingApproval)]),
            .needsAttention
        )
    }

    // MARK: - Seen tracking in the reducer

    func testNewPromptMarksTheFinishedTurnSeen() throws {
        var sessions = ["s1": session(.idle, unseen: true)]
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "next",
        ])
        _ = reduceEvent(sessions: &sessions, event: try XCTUnwrap(HookEvent(from: data)), maxHistory: 20)
        XCTAssertEqual(sessions["s1"]?.completionUnseen, false)
    }

    // MARK: - Animation timeline (rows/durations from white-cat-signal integration.json)

    // The cat holds still; a state's row plays once only when the lamp changes.

    func testWorkingPlaysRunningRowOnceThenHoldsItsFirstFrame() {
        let t = SignalPetAnimation.timeline(for: .working)
        XCTAssertEqual(t.transition.map(\.row), Array(repeating: 7, count: 6))
        XCTAssertEqual(t.transition.map(\.column), Array(0..<6))
        XCTAssertEqual(t.transition.map(\.durationMs), [120, 120, 120, 120, 120, 220])
        XCTAssertEqual(t.hold, SignalPetFrame(row: 7, column: 0, durationMs: 120))
    }

    func testAwaitingInputWavesOnceThenHoldsTheSleepingFrame() {
        let t = SignalPetAnimation.timeline(for: .awaitingInput)
        XCTAssertEqual(t.transition.map(\.row), Array(repeating: 3, count: 4))
        XCTAssertEqual(t.transition.map(\.column), [0, 1, 2, 3])
        XCTAssertEqual(t.hold.row, 0)
        XCTAssertEqual(t.hold.column, 0)
    }

    func testRedStatesUseWaitingAndFailedRows() {
        XCTAssertEqual(SignalPetAnimation.timeline(for: .needsAttention).transition.map(\.row), Array(repeating: 6, count: 6))
        XCTAssertEqual(SignalPetAnimation.timeline(for: .needsAttention).hold.row, 6)
        XCTAssertEqual(SignalPetAnimation.timeline(for: .failed).transition.map(\.row), Array(repeating: 5, count: 8))
        XCTAssertEqual(SignalPetAnimation.timeline(for: .failed).hold.row, 5)
    }

    func testAnimatesOnlyWhenTheLampChanges() {
        XCTAssertTrue(SignalPetAnimation.animatesTransition(from: .working, to: .awaitingInput))
        XCTAssertTrue(SignalPetAnimation.animatesTransition(from: .failed, to: .working))
        // Same red lamp: the still frame just swaps.
        XCTAssertFalse(SignalPetAnimation.animatesTransition(from: .needsAttention, to: .failed))
        // First state at launch: shown still.
        XCTAssertFalse(SignalPetAnimation.animatesTransition(from: nil, to: .needsAttention))
    }

    func testCellRectFollowsAtlasGrid() {
        let frame = SignalPetFrame(row: 6, column: 2, durationMs: 150)
        XCTAssertEqual(frame.cellOrigin.x, 384)
        XCTAssertEqual(frame.cellOrigin.y, 1248)
    }
}
