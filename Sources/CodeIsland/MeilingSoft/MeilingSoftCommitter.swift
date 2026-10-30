import AppKit
import Foundation

/// Puts dictated sentences at the cursor through the 美玲 input method's standard commit (insertText) — never
/// the clipboard, never AX value writes or synthetic paste (unreliable insertion is why this project exists).
/// One sentence at a time: hand the text to the input method (prepare) → select 美玲 → the input method inserts it
/// inside its activation and says "committed" (≤ 600 ms) → restore the user's input source.
/// Why not "select, wait for activated, then commit" (until 2026-10-29): iTerm2 and Lark drop the input method about
/// 2 ms after a programmatic switch, so a commit sent after the "activated" message often found no client (18 of
/// 121 sentences lost on 2026-10-29). No "committed": ask the input method whether the text is still waiting
/// (cancel); if it went in, that is a success (never typed twice); if not, switch away and back and try again, at
/// most three times, then give the sentence up (it stays in the dictation history). Each sentence logs its steps.
@MainActor
final class MeilingSoftCommitter {
    enum Outcome: Equatable {
        case ok(ms: Int)
        case notInstalled, inactive, unreachable, cancelled
    }

    static let committedTimeout: TimeInterval = 0.6
    static let attempts = 3, reselectDelay: TimeInterval = 0.1

    private let switcher: MeilingCommitSwitching
    private let ime: MeilingCommitIME
    private let observeCommitted: (@escaping () -> Void) -> Void
    private let log: (String) -> Void
    private var queue: [(String, (Outcome) -> Void)] = []
    private var busy = false
    private var waiting: ((Bool) -> Void)?  // true: the input method said "committed"
    private var waitID = 0                   // which wait the pending timeout belongs to
    private var observing = false
    private var abandoned = false

    /// observeCommitted: registers the callback for the input method's "committed" message (once).
    /// log: one line per sentence (the real one writes ~/Library/Logs/AISM/meiling.log; tests keep it quiet).
    init(switcher: MeilingCommitSwitching, ime: MeilingCommitIME, log: @escaping (String) -> Void = { _ in },
         observeCommitted: @escaping (@escaping () -> Void) -> Void) {
        self.switcher = switcher
        self.ime = ime
        self.log = log
        self.observeCommitted = observeCommitted
    }

    convenience init() {
        let file = MeilingLog()
        self.init(switcher: MeilingInputSwitcher(), ime: MeilingIMEClient(), log: { file.write($0) }) { committed in
            MeilingAppPort.shared.addCommittedObserver { _ in committed() }
            MeilingAppPort.shared.start()
        }
    }

    /// Drops sentences not yet written (a cancelled talk). The one being written is abandoned: its prepared text is
    /// withdrawn unless the input method already inserted it.
    func cancelPending() {
        queue.removeAll()
        if let resume = waiting {
            waiting = nil
            abandoned = true
            resume(false)
        }
    }

    func commit(_ text: String, done: @escaping (Outcome) -> Void) {
        if !observing {
            observeCommitted { [weak self] in
                MainActor.assumeIsolated {
                    let resume = self?.waiting
                    self?.waiting = nil
                    resume?(true)
                }
            }
            observing = true
        }
        queue.append((text, done))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (text, done) = queue.removeFirst()
        let started = Date()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        var trace: [String] = []  // for the log: steps and timings, never the text
        let note: (String) -> Void = { trace.append($0) }
        let finish: (Outcome) -> Void = { [weak self] outcome in
            self?.switcher.restore()
            self?.log("commit: front=\(front) \(trace.joined(separator: " ")) -> \(outcome)")
            done(outcome)
            // Let TIS apply the restore before the next sentence checks which source is active.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.busy = false
                self?.next()
            }
        }
        let ok = { finish(.ok(ms: Int(Date().timeIntervalSince(started) * 1000))) }
        note("wasActive=\(switcher.meilingActive)")
        if switcher.meilingActive {
            // Already selected (and so already bound to the focused client): insert straight away.
            let result = ime.commit(text)
            note("direct=\(result)")
            switch result {
            case .ok: return ok()
            case .unreachable: return finish(.unreachable)
            case .inactive: break  // bound to nothing: go the prepared way, switching away and back first
            }
            attempt(text, 1, note, ok, finish)
        } else {
            attempt(text, 0, note, ok, finish)
        }
    }

    /// One prepared try: hand the text over, select 美玲 (after switching away when n > 0), wait for "committed".
    private func attempt(_ text: String, _ n: Int, _ note: @escaping (String) -> Void, _ ok: @escaping () -> Void,
                         _ finish: @escaping (Outcome) -> Void) {
        guard ime.prepare(text) == .ok else { return finish(.unreachable) }
        let settle: (Bool) -> Void = { [weak self] committed in
            guard let self else { return }
            if committed && !self.abandoned {
                note("try\(n)=committed")
                return ok()
            }
            // No word from the input method: did the text go in anyway?
            let state = self.ime.cancelPending()
            note("try\(n)=\(committed ? "committed" : "silent")/\(state)")
            if state == .consumed {
                self.abandoned = false
                return ok()
            }
            if state == .unreachable { return finish(.unreachable) }
            if self.abandoned {
                self.abandoned = false
                return finish(.cancelled)
            }
            if n + 1 < Self.attempts { return self.attempt(text, n + 1, note, ok, finish) }
            finish(.inactive)
        }
        let started = Date()
        let select = { [weak self] in
            guard let self else { return }
            self.waitID &+= 1
            let id = self.waitID
            self.waiting = { committed in
                if committed { note("committed=\(Int(Date().timeIntervalSince(started) * 1000))ms") }
                settle(committed)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.committedTimeout) { [weak self] in
                // Only this wait's own timeout: a later attempt or sentence has its own waiter.
                guard let self, self.waitID == id, let resume = self.waiting else { return }
                self.waiting = nil
                resume(false)
            }
            guard self.switcher.selectMeiling() else {
                self.waiting = nil
                _ = self.ime.cancelPending()
                return finish(.notInstalled)
            }
        }
        if n == 0 { return select() }
        switcher.selectOther()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reselectDelay) { select() }
    }
}
