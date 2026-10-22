import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The desktop signal-cat only lights blue for finished turns nobody looked
/// at. AppState marks a turn unseen when it completes and seen on the same
/// signals follow-up reminders use: a jump to its terminal, a hover on its
/// completion card, or opening the session list.
@MainActor
final class SignalPetSeenTests: XCTestCase {
    private var appState: AppState!
    private var savedStyle: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedStyle = UserDefaults.standard.object(forKey: SettingsKey.completionNotificationStyle)
        // Glance keeps completions off the card path so the surface stays put.
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        appState = AppState()
        appState.followUps.armsTimer = false
    }

    override func tearDown() async throws {
        appState = nil
        if let savedStyle {
            UserDefaults.standard.set(savedStyle, forKey: SettingsKey.completionNotificationStyle)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.completionNotificationStyle)
        }
        try await super.tearDown()
    }

    func testFinishedTurnStartsUnseen() throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "done"]))
        XCTAssertEqual(appState.sessions["done"]?.completionUnseen, true)
        XCTAssertEqual(SignalPetState.resolve(appState.sessions.values), .awaitingInput)
    }

    func testJumpingToTheTerminalMarksItSeen() throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "jumped"]))
        NotificationCenter.default.post(name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": "jumped"])
        XCTAssertEqual(appState.sessions["jumped"]?.completionUnseen, false)
        XCTAssertEqual(SignalPetState.resolve(appState.sessions.values), .working)
    }

    func testHoveringTheCompletionCardMarksItSeen() throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "hovered"]))
        appState.surface = .completionCard(sessionId: "hovered")
        appState.completionHasBeenEntered = true
        XCTAssertEqual(appState.sessions["hovered"]?.completionUnseen, false)
    }

    func testOpeningTheSessionListMarksEveryTurnSeen() throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "a"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "b"]))
        appState.surface = .sessionList
        XCTAssertEqual(appState.sessions["a"]?.completionUnseen, false)
        XCTAssertEqual(appState.sessions["b"]?.completionUnseen, false)
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
