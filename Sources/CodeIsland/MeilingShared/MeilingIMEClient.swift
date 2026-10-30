import Foundation
import MeilingIPC

/// The app side of the Meyrin input method wire (MeilingIPC).

enum MeilingPrepareResult: Equatable { case ok, unreachable }
enum MeilingCancelResult: Equatable { case cleared, consumed, unreachable }

/// What the software-mode committer needs from the input method (a fake in the tests).
protocol MeilingCommitIME: AnyObject {
    func commit(_ text: String) -> MeilingIMEClient.CommitResult
    func prepare(_ text: String) -> MeilingPrepareResult
    func cancelPending() -> MeilingCancelResult
}

final class MeilingIMEClient: MeilingCommitIME {
    enum CommitResult: Equatable { case ok, inactive, unreachable }

    func commit(_ text: String) -> CommitResult {
        guard let reply = send(MeilingIPC.commit, Data(text.utf8)) else { return .unreachable }
        return reply == MeilingIPC.ok ? .ok : .inactive
    }

    /// Hands the text over before the switch: the input method inserts it inside its next activation.
    func prepare(_ text: String) -> MeilingPrepareResult {
        send(MeilingIPC.prepare, Data(text.utf8)) == MeilingIPC.ok ? .ok : .unreachable
    }

    /// Drops a prepared text that is still waiting; `consumed` when nothing waits (it was inserted).
    func cancelPending() -> MeilingCancelResult {
        guard let reply = send(MeilingIPC.cancel, Data()) else { return .unreachable }
        return reply == MeilingIPC.pending ? .cleared : .consumed
    }

    private func send(_ msgid: Int32, _ payload: Data) -> String? {
        guard let port = CFMessagePortCreateRemote(nil, MeilingIPC.imePort as CFString) else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, msgid, payload as CFData, 0.5, 0.5,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data? else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Receives the input method's "activated" / "committed" messages on the main run loop. One port per process (the
/// name is global), shared by the Tab5 key-frame coordinator and the Mac-only dictation (MeilingSoft).
final class MeilingAppPort {
    static let shared = MeilingAppPort()
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private var observers: [(String) -> Void] = []
    private var committedObservers: [(String) -> Void] = []

    func addObserver(_ observer: @escaping (String) -> Void) {
        observers.append(observer)
    }

    /// A prepared text went in on activation (the bundle id of the client).
    func addCommittedObserver(_ observer: @escaping (String) -> Void) {
        committedObservers.append(observer)
    }

    fileprivate func onMessage(_ msgid: Int32, _ bundle: String) {
        if msgid == MeilingIPC.activated { observers.forEach { $0(bundle) } }
        if msgid == MeilingIPC.committed { committedObservers.forEach { $0(bundle) } }
    }

    func start() {
        guard port == nil else { return }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, msgid, data, info in
            guard msgid == MeilingIPC.activated || msgid == MeilingIPC.committed, let info else { return nil }
            let me = Unmanaged<MeilingAppPort>.fromOpaque(info).takeUnretainedValue()
            let bundle = (data as Data?).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            me.onMessage(msgid, bundle)
            return nil
        }
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, MeilingIPC.appPort as CFString, callback, &context, &shouldFree)
        else { return }
        port = local
        source = CFMessagePortCreateRunLoopSource(nil, local, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}
