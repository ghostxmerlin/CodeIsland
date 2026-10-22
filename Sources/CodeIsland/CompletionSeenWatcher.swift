import AppKit
import CodeIslandCore

/// Looking at a session's own pane counts as seeing its finished turn, however
/// the user got there — a jump from the island, or switching Herdr panes /
/// terminal tabs by hand. While any turn is unseen, polls the same detectors
/// Smart Suppress uses: app level first, tab level (which may block on
/// AppleScript or a multiplexer CLI) detached and only when the app is in front.
/// With nothing unseen it arms no timer.
@MainActor
final class CompletionSeenWatcher {
    weak var appState: AppState?

    var terminalFrontmost: (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    var tabVisible: @Sendable (SessionSnapshot) -> Bool = { session in
        TerminalVisibilityDetector.isSessionTabVisible(session)
    }
    /// Called with each session id whose tab is probed. Tests observe the cost.
    var onProbe: (String) -> Void = { _ in }
    /// Tests drive `check()` by hand and turn the real timer off.
    var armsTimer = true
    var pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var isChecking = false

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        timer?.invalidate()
    }

    /// Call whenever sessions change: polls while a turn is unseen, and checks
    /// right away so a turn that ends while its pane is in front never lights.
    func sessionsChanged() {
        let anyUnseen = appState?.sessions.values.contains { $0.completionUnseen } ?? false
        guard anyUnseen else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard armsTimer, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func check() async {
        guard !isChecking, let appState else { return }
        isChecking = true
        defer { isChecking = false }
        let candidates = appState.sessions.filter { $0.value.completionUnseen && terminalFrontmost($0.value) }
        for (sessionId, session) in candidates {
            onProbe(sessionId)
            let probe = tabVisible
            let visible = await Task.detached(priority: .utility) { probe(session) }.value
            if visible {
                appState.markCompletionSeen(sessionId: sessionId)
            }
        }
    }
}
