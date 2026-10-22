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

    // MARK: - Dragging and clicking the cat

    func testDraggingRunsTowardTheDragDirection() {
        let right = SignalPetAnimation.dragLoop(.right)
        XCTAssertEqual(right.map(\.row), Array(repeating: 1, count: 8))
        XCTAssertEqual(right.map(\.column), Array(0..<8))
        XCTAssertEqual(right.map(\.durationMs), [120, 120, 120, 120, 120, 120, 120, 220])
        // Separate artwork, not a mirror: the signal stays on screen-right.
        XCTAssertEqual(SignalPetAnimation.dragLoop(.left).map(\.row), Array(repeating: 2, count: 8))
    }

    func testClickJumpsOnce() {
        let poke = SignalPetAnimation.poke
        XCTAssertEqual(poke.map(\.row), Array(repeating: 4, count: 5))
        XCTAssertEqual(poke.map(\.durationMs), [140, 140, 140, 140, 280])
    }

    func testHorizontalMotionPicksTheRunDirection() {
        XCTAssertEqual(SignalPetDragDirection.right.updated(dx: -4), .left)
        XCTAssertEqual(SignalPetDragDirection.left.updated(dx: 4), .right)
        // Pure vertical drags and sub-point jitter keep the current direction.
        XCTAssertEqual(SignalPetDragDirection.left.updated(dx: 0), .left)
        XCTAssertEqual(SignalPetDragDirection.left.updated(dx: 0.5), .left)
    }

    func testOnlyAPressThatBarelyMovesIsAClick() {
        XCTAssertTrue(SignalPetDragDirection.isClick(dx: 1, dy: -2))
        XCTAssertFalse(SignalPetDragDirection.isClick(dx: 0, dy: 5))
    }

    func testCellRectFollowsAtlasGrid() {
        let frame = SignalPetFrame(row: 6, column: 2, durationMs: 150)
        XCTAssertEqual(frame.cellOrigin.x, 384)
        XCTAssertEqual(frame.cellOrigin.y, 1248)
    }
}
