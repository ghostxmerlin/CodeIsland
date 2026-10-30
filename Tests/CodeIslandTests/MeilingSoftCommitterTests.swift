import XCTest
import MeilingIPC
@testable import CodeIsland

/// Meyrin (software mode) commits, 2026-10-29. The log showed iTerm2 and Lark deactivating the input method about
/// 2 ms after a programmatic switch, so "switch, wait for activated, send the text" raced that window (18 of 121
/// sentences lost that day). Now the text is handed over first and the input method inserts it inside its own
/// activation, then says "committed".
@MainActor
final class MeilingSoftCommitterTests: XCTestCase {
    /// The input method as the app sees it: prepare / cancel / direct commit, and what one activation does.
    final class FakeIME: MeilingCommitIME {
        var pending: String?
        var inserted: [String] = []
        var prepares = 0, directCommits = 0
        var reachable = true
        var activationInserts = true   // false: the client drops the input method before it can insert
        var reportsCommitted = true     // false: the "committed" message is lost on the way
        var onCommitted: (() -> Void)?

        func prepare(_ text: String) -> MeilingPrepareResult {
            guard reachable else { return .unreachable }
            prepares += 1
            pending = text
            return .ok
        }
        func cancelPending() -> MeilingCancelResult {
            guard reachable else { return .unreachable }
            if pending == nil { return .consumed }
            pending = nil
            return .cleared
        }
        func commit(_ text: String) -> MeilingIMEClient.CommitResult {
            directCommits += 1
            inserted.append(text)
            return .ok
        }
        /// The client activated the input method (a switch to Meyrin).
        func activate() {
            guard activationInserts, let text = pending else { return }
            pending = nil
            inserted.append(text)
            if reportsCommitted { DispatchQueue.main.async { self.onCommitted?() } }
        }
    }

    final class FakeSwitcher: MeilingCommitSwitching {
        var meilingActive = false
        var installed = true
        var selects = 0, others = 0, restores = 0
        var onSelect: (() -> Void)?
        func selectMeiling() -> Bool {
            guard installed else { return false }
            selects += 1
            meilingActive = true
            onSelect?()
            return true
        }
        func selectOther() { others += 1; meilingActive = false }
        func restore() { restores += 1; meilingActive = false }
    }

    private func make() -> (MeilingSoftCommitter, FakeIME, FakeSwitcher) {
        let ime = FakeIME(), switcher = FakeSwitcher()
        switcher.onSelect = { ime.activate() }
        let committer = MeilingSoftCommitter(switcher: switcher, ime: ime) { committed in ime.onCommitted = committed }
        return (committer, ime, switcher)
    }

    private func outcome(_ committer: MeilingSoftCommitter, _ text: String) -> MeilingSoftCommitter.Outcome? {
        let done = expectation(description: "commit")
        var result: MeilingSoftCommitter.Outcome?
        committer.commit(text) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    func testPreparedTextLandsInsideTheActivation() {
        let (committer, ime, switcher) = make()
        guard case .ok = outcome(committer, "第一句。") else { return XCTFail("not ok") }
        XCTAssertEqual(ime.inserted, ["第一句。"])
        XCTAssertEqual(ime.directCommits, 0)  // no racing IPC commit after the switch
        XCTAssertEqual(switcher.restores, 1)
    }

    func testLostCommittedMessageStillCountsWhenTheTextWasConsumed() {
        let (committer, ime, switcher) = make()
        ime.reportsCommitted = false
        guard case .ok = outcome(committer, "第二句。") else { return XCTFail("not ok") }
        XCTAssertEqual(ime.inserted, ["第二句。"])  // typed once, never twice
        XCTAssertEqual(switcher.restores, 1)
    }

    func testActivationThatCannotInsertRetriesWithAReselectThenGivesUp() {
        let (committer, ime, switcher) = make()
        ime.activationInserts = false
        XCTAssertEqual(outcome(committer, "第三句。"), .inactive)
        XCTAssertTrue(ime.inserted.isEmpty)
        XCTAssertNil(ime.pending)  // nothing left behind to type later
        XCTAssertEqual(ime.prepares, 3)
        XCTAssertEqual(switcher.others, 2)  // switched away and back before each retry
        XCTAssertEqual(switcher.restores, 1)
    }

    func testAReselectThatWorksRecovers() {
        let (committer, ime, switcher) = make()
        ime.activationInserts = false
        switcher.onSelect = { [weak ime] in
            guard let ime else { return }
            if switcher.selects >= 2 { ime.activationInserts = true }
            ime.activate()
        }
        guard case .ok = outcome(committer, "第四句。") else { return XCTFail("not ok") }
        XCTAssertEqual(ime.inserted, ["第四句。"])
    }

    func testAlreadyActiveCommitsDirectly() {
        let (committer, ime, switcher) = make()
        switcher.meilingActive = true
        guard case .ok = outcome(committer, "第五句。") else { return XCTFail("not ok") }
        XCTAssertEqual(ime.directCommits, 1)
        XCTAssertEqual(ime.prepares, 0)
    }

    func testNotInstalledAndUnreachable() {
        let (committer, ime, switcher) = make()
        switcher.installed = false
        XCTAssertEqual(outcome(committer, "x"), .notInstalled)
        XCTAssertNil(ime.pending)
        switcher.installed = true
        ime.reachable = false
        XCTAssertEqual(outcome(committer, "y"), .unreachable)
    }

    func testSentencesGoOutInOrder() {
        let (committer, ime, _) = make()
        let done = expectation(description: "both")
        done.expectedFulfillmentCount = 2
        committer.commit("一。") { _ in done.fulfill() }
        committer.commit("二。") { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(ime.inserted, ["一。", "二。"])
    }

    func testPendingTextExpiresAndIsTakenOnce() {
        var pending = MeilingPendingText()
        let t0 = Date()
        pending.set("a", now: t0)
        XCTAssertEqual(pending.take(now: t0.addingTimeInterval(0.5)), "a")
        XCTAssertNil(pending.take(now: t0.addingTimeInterval(0.6)))  // taken once
        pending.set("b", now: t0)
        XCTAssertNil(pending.take(now: t0.addingTimeInterval(MeilingPendingText.maxAge + 0.1)))  // stale: dropped
        pending.set("c", now: t0)
        XCTAssertTrue(pending.clear())   // was waiting
        XCTAssertFalse(pending.clear())  // nothing left
    }
}
