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
        IMELog.write("activate \(bundle) \(ObjectIdentifier(self).hashValue)")
        MeilingCommitPort.notifyActivated(bundle: bundle)
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

    func start() {
        let callback: CFMessagePortCallBack = { _, msgid, data, _ in
            guard msgid == MeilingIPC.commit, let data = data as Data?, let text = String(data: data, encoding: .utf8) else { return nil }
            let controller = MeilingController.active
            let ok = controller?.commit(text) ?? false
            IMELog.write("commit \(ok ? "ok" : controller == nil ? "inactive (no active controller)" : "inactive (no client)")")
            return Unmanaged.passRetained(Data((ok ? MeilingIPC.ok : MeilingIPC.inactive).utf8) as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, MeilingIPC.imePort as CFString, callback, nil, &shouldFree)
        else { return }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
    }

    static func notifyActivated(bundle: String) {
        guard let remote = CFMessagePortCreateRemote(nil, MeilingIPC.appPort as CFString) else { return }
        CFMessagePortSendRequest(remote, MeilingIPC.activated, Data(bundle.utf8) as CFData, 0.2, 0, nil, nil)
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
