import AppKit
import InputMethodKit

/// One controller per client text view. The most recently activated one is the commit target.
@objc(MeilingController)
final class MeilingController: IMKInputController {
    nonisolated(unsafe) static weak var active: MeilingController?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.active = self
        let bundle = (sender as? IMKTextInput)?.bundleIdentifier() ?? ""
        MeilingCommitPort.notifyActivated(bundle: bundle)
    }

    override func deactivateServer(_ sender: Any!) {
        if Self.active === self { Self.active = nil }
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

/// aism → IME "com.aism.meiling.ime" msgid 1 = commit (UTF-8), reply "ok" / "inactive".
/// IME → aism "com.aism.meiling.app" msgid 2 = activated (client bundle id).
final class MeilingCommitPort {
    static let shared = MeilingCommitPort()
    private var port: CFMessagePort?

    func start() {
        let callback: CFMessagePortCallBack = { _, msgid, data, _ in
            guard msgid == 1, let data = data as Data?, let text = String(data: data, encoding: .utf8) else { return nil }
            let ok = MeilingController.active?.commit(text) ?? false
            return Unmanaged.passRetained(Data((ok ? "ok" : "inactive").utf8) as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, "com.aism.meiling.ime" as CFString, callback, nil, &shouldFree)
        else { return }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
    }

    static func notifyActivated(bundle: String) {
        guard let remote = CFMessagePortCreateRemote(nil, "com.aism.meiling.app" as CFString) else { return }
        CFMessagePortSendRequest(remote, 2, Data(bundle.utf8) as CFData, 0.2, 0, nil, nil)
    }
}
