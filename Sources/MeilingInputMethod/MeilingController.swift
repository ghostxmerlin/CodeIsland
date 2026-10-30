import AppKit
import InputMethodKit
import MeilingIPC

/// One controller per client text view. The most recently activated one is the commit target.
@objc(MeilingController)
final class MeilingController: IMKInputController {
    nonisolated(unsafe) static weak var active: MeilingController?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.active = self
        let bundle = (sender as? IMKTextInput)?.bundleIdentifier() ?? ""
        // A prepared sentence goes in here, inside the activation: some clients (iTerm2, Lark) drop the input
        // method ~2 ms after a programmatic switch, before a separate commit request could arrive (2026-10-29).
        if let text = MeilingCommitPort.shared.pending.take() {
            let ok = commit(text)
            IMELog.write("activate \(bundle) \(ObjectIdentifier(self).hashValue) prepared \(ok ? "ok" : "no client")")
            if ok {
                MeilingCommitPort.notify(MeilingIPC.committed, bundle: bundle)
                return
            }
            MeilingCommitPort.shared.pending.set(text)  // no client after all: leave it for the app to withdraw
        } else {
            IMELog.write("activate \(bundle) \(ObjectIdentifier(self).hashValue)")
        }
        MeilingCommitPort.notify(MeilingIPC.activated, bundle: bundle)
    }

    override func deactivateServer(_ sender: Any!) {
        let wasActive = Self.active === self
        if wasActive { Self.active = nil }
        IMELog.write("deactivate \((sender as? IMKTextInput)?.bundleIdentifier() ?? "") \(ObjectIdentifier(self).hashValue) wasActive=\(wasActive)")
        super.deactivateServer(sender)
    }

    /// Never consume keys: the Tab5's frame keys are swallowed by aism's tap; the user's own keys pass.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }

    func commit(_ text: String) -> Bool {
        guard let client = client() else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}

/// The input method side of the wire (MeilingIPC): commit requests in, "activated" out.
final class MeilingCommitPort {
    static let shared = MeilingCommitPort()
    private var port: CFMessagePort?
    var pending = MeilingPendingText()  // main run loop only (port callbacks and activateServer)

    func start() {
        let callback: CFMessagePortCallBack = { _, msgid, data, _ in
            let reply = { (text: String) in Unmanaged.passRetained(Data(text.utf8) as CFData) }
            switch msgid {
            case MeilingIPC.commit:
                guard let data = data as Data?, let text = String(data: data, encoding: .utf8) else { return nil }
                let controller = MeilingController.active
                let ok = controller?.commit(text) ?? false
                IMELog.write("commit \(ok ? "ok" : controller == nil ? "inactive (no active controller)" : "inactive (no client)")")
                return reply(ok ? MeilingIPC.ok : MeilingIPC.inactive)
            case MeilingIPC.prepare:
                guard let data = data as Data?, let text = String(data: data, encoding: .utf8) else { return nil }
                MeilingCommitPort.shared.pending.set(text)
                IMELog.write("prepare")
                return reply(MeilingIPC.ok)
            case MeilingIPC.cancel:
                let wasWaiting = MeilingCommitPort.shared.pending.clear()
                IMELog.write("cancel \(wasWaiting ? "dropped" : "nothing waiting")")
                return reply(wasWaiting ? MeilingIPC.pending : MeilingIPC.none)
            default:
                return nil
            }
        }
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, MeilingIPC.imePort as CFString, callback, nil, &shouldFree)
        else { return }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
    }

    static func notify(_ msgid: Int32, bundle: String) {
        guard let remote = CFMessagePortCreateRemote(nil, MeilingIPC.appPort as CFString) else { return }
        CFMessagePortSendRequest(remote, msgid, Data(bundle.utf8) as CFData, 0.2, 0, nil, nil)
    }
}

/// ~/Library/Logs/AISM/meiling-ime.log: activation and commit outcomes, never the text. Kept under 256 KB.
enum IMELog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AISM")
        let url = dir.appendingPathComponent("meiling-ime.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 << 10 {
            try? FileManager.default.removeItem(at: url)
        }
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
