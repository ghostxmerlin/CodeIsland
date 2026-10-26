import AppKit
import Foundation

/// Puts dictated sentences at the cursor through the 美玲 input method's standard commit (insertText) — never
/// the clipboard, never AX value writes or synthetic paste (unreliable insertion is why this project exists).
/// One sentence at a time: select 美玲 → wait for its activation in the focused client (≤ 600 ms) → commit →
/// restore the user's input source. An "inactive" answer (the input method has no client, e.g. it was not woken in
/// the focused app) is retried, once with 美玲 selected again, before the sentence is given up (it stays in the
/// dictation history). Each sentence logs its steps.
@MainActor
final class MeilingSoftCommitter {
    enum Outcome: Equatable {
        case ok(ms: Int)
        case notInstalled, inactive, unreachable, cancelled
    }

    static let activationTimeout: TimeInterval = 0.6
    static let inactiveRetries = 3, retryDelay: TimeInterval = 0.3

    private let switcher = MeilingInputSwitcher()
    private let ime = MeilingIMEClient()
    private let log = MeilingLog()
    private var queue: [(String, (Outcome) -> Void)] = []
    private var busy = false
    private var waiting: (() -> Void)?
    private var observing = false
    private var abandoned = false
    private var retrying = false  // between "inactive" retries of the sentence being written

    /// Drops sentences not yet written (a cancelled talk). One already being written is let through only if its
    /// commit has started; the activation wait is abandoned.
    func cancelPending() {
        queue.removeAll()
        if retrying { abandoned = true }
        if let resume = waiting {
            waiting = nil
            abandoned = true
            resume()
        }
    }

    func commit(_ text: String, done: @escaping (Outcome) -> Void) {
        if !observing {
            MeilingAppPort.shared.addObserver { [weak self] _ in
                MainActor.assumeIsolated {
                    let resume = self?.waiting
                    self?.waiting = nil
                    resume?()
                }
            }
            MeilingAppPort.shared.start()
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
            self?.log.write("commit: front=\(front) \(trace.joined(separator: " ")) -> \(outcome)")
            done(outcome)
            // Let TIS apply the restore before the next sentence checks which source is active.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.busy = false
                self?.next()
            }
        }
        // After an "inactive" answer: resend once, then switch away from 美玲 and back (the focused client then
        // activates the input method again) and resend, then a last resend; only then give the sentence up.
        var step = 0
        var attempt: (() -> Void)!
        attempt = { [weak self] in
            guard let self else { return }
            self.retrying = false
            if self.abandoned {
                self.abandoned = false
                self.switcher.restore()
                attempt = nil  // it captures itself: break the cycle once the sentence is done
                finish(.cancelled)
                return
            }
            let result = self.ime.commit(text)
            note("try\(step)=\(result)")
            if result == .inactive, step < Self.inactiveRetries {
                step += 1
                self.retrying = true
                if step == 2 {
                    self.switcher.selectOther()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        note("reselect=\(self.switcher.selectMeiling())")
                        self.waitForActivation(note) { attempt?() }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { attempt?() }
                }
                return
            }
            attempt = nil
            self.switcher.restore()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .ok: finish(.ok(ms: ms))
            case .inactive: finish(.inactive)
            case .unreachable: finish(.unreachable)
            }
        }
        note("wasActive=\(switcher.meilingActive)")
        if switcher.meilingActive {
            attempt?()
            return
        }
        guard switcher.selectMeiling() else {
            switcher.restore()
            finish(.notInstalled)
            return
        }
        waitForActivation(note) { attempt?() }
    }

    /// Waits for the input method's "activated" message, at most `activationTimeout`. No message (the client was
    /// already bound, or the IME is slow) still goes on: the IME answers "inactive" when it has no client.
    private func waitForActivation(_ note: @escaping (String) -> Void, then go: @escaping () -> Void) {
        let asked = Date()
        var fired = false
        let once: (String) -> Void = { how in
            guard !fired else { return }
            fired = true
            note("activation=\(how)")
            go()
        }
        waiting = { once("\(Int(Date().timeIntervalSince(asked) * 1000))ms") }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationTimeout) { [weak self] in
            if !fired { self?.waiting = nil }  // a later sentence may already be waiting: leave its hook alone
            once("timeout")
        }
    }
}
