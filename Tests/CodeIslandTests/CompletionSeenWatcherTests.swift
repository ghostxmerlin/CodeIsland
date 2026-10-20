import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Looking at a session's own pane counts as seeing its finished turn, even
/// when the user got there without CodeIsland (switching Herdr panes, iTerm
/// tabs…). The terminal probes are injected; the poll timer is off.
@MainActor
final class CompletionSeenWatcherTests: XCTestCase {
    /// Read by the tab probe off the main actor; written only between checks.
    private final class VisiblePanes: @unchecked Sendable {
        var ids: Set<String> = []
    }

    private var appState: AppState!
    private var watcher: CompletionSeenWatcher!
    private var frontmost = true
    private let visiblePanes = VisiblePanes()
    private var visible: Set<String> {
        get { visiblePanes.ids }
        set { visiblePanes.ids = newValue }
    }
    private var probed: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        appState = AppState()
        appState.followUps.armsTimer = false
        watcher = CompletionSeenWatcher(appState: appState)
        watcher.armsTimer = false
        watcher.terminalFrontmost = { [unowned self] _ in self.frontmost }
        watcher.tabVisible = { [visiblePanes] session in
            visiblePanes.ids.contains(session.cwd ?? "")
        }
        watcher.onProbe = { [unowned self] in self.probed.append($0) }
    }

    override func tearDown() async throws {
        watcher = nil
        appState = nil
        try await super.tearDown()
    }

    private func finish(_ sid: String) {
        var session = SessionSnapshot()
        session.cwd = sid
        session.status = .idle
        session.completionUnseen = true
        appState.sessions[sid] = session
    }

    func testFocusedPaneMarksItsTurnSeen() async {
        finish("a")
        finish("b")
        visible = ["a"]
        await watcher.check()
        XCTAssertEqual(appState.sessions["a"]?.completionUnseen, false)
        XCTAssertEqual(appState.sessions["b"]?.completionUnseen, true)
    }

    func testPaneFocusedBehindAnotherAppDoesNotCount() async {
        finish("a")
        visible = ["a"]
        frontmost = false
        await watcher.check()
        XCTAssertEqual(appState.sessions["a"]?.completionUnseen, true)
    }

    func testNothingUnseenProbesNothing() async {
        var session = SessionSnapshot()
        session.cwd = "seen"
        appState.sessions["seen"] = session
        await watcher.check()
        XCTAssertEqual(probed, [])
    }
}
