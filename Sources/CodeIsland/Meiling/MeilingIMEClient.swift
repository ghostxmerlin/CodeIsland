import Foundation

/// aism ⇄ MeilingInputMethod over local CFMessagePorts (no distributed notifications: dictated text stays private).
///   aism → IME  "com.aism.meiling.ime"  msgid 1 = commit (UTF-8 text); reply "ok" or "inactive"
///   IME → aism  "com.aism.meiling.app"  msgid 2 = activated (data = client bundle id)
enum MeilingIPC {
    static let imePort = "com.aism.meiling.ime", appPort = "com.aism.meiling.app"
    static let commit: Int32 = 1, activated: Int32 = 2
}

final class MeilingIMEClient {
    enum CommitResult: Equatable { case ok, inactive, unreachable }

    func commit(_ text: String) -> CommitResult {
        guard let port = CFMessagePortCreateRemote(nil, MeilingIPC.imePort as CFString) else { return .unreachable }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, MeilingIPC.commit, Data(text.utf8) as CFData, 0.5, 0.5,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data? else { return .unreachable }
        return String(data: data, encoding: .utf8) == "ok" ? .ok : .inactive
    }
}

/// Receives the input method's "activated" message on the main run loop. One port per process (the name is
/// global), shared by the Tab5 key-frame coordinator and the Mac-only dictation (MeilingSoft).
final class MeilingAppPort {
    static let shared = MeilingAppPort()
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private var observers: [(String) -> Void] = []

    func addObserver(_ observer: @escaping (String) -> Void) {
        observers.append(observer)
    }

    fileprivate func onActivated(_ bundle: String) {
        observers.forEach { $0(bundle) }
    }

    func start() {
        guard port == nil else { return }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, msgid, data, info in
            guard msgid == MeilingIPC.activated, let info else { return nil }
            let me = Unmanaged<MeilingAppPort>.fromOpaque(info).takeUnretainedValue()
            let bundle = (data as Data?).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            me.onActivated(bundle)
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
