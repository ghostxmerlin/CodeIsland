import AppKit

/// The status-item submenu "Meyrin (Tab5)" for the Tab5 hardware mode: enable the key tap, install the input method, captions, LED bench.
@MainActor
final class MeilingMenu: NSObject, NSMenuDelegate {
    static let shared = MeilingMenu()
    let menu = NSMenu(title: "Meyrin (Tab5)")
    private let enabled = NSMenuItem(title: "Enable (capture Tab5 keys)", action: #selector(toggleEnabled), keyEquivalent: "")
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        menu.delegate = self
        enabled.target = self
        menu.addItem(enabled)
        menu.addItem(status)
        menu.addItem(.separator())
        add("Install Meyrin Input Method", #selector(installInputMethod))
        add("Show Captions", #selector(showCaptions))
        add("Larger Captions", #selector(fontUp))
        add("Smaller Captions", #selector(fontDown))
        menu.addItem(.separator())
        add("Test Keyboard LED Ack", #selector(ledTest))
    }

    private func add(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let coordinator = MeilingCoordinator.shared
        enabled.state = coordinator.running ? .on : .off
        status.title = coordinator.lastError ?? (MeilingInputSwitcher.installed ? "Meyrin input method: enabled" : "Meyrin input method: not installed or not enabled")
    }

    @objc private func toggleEnabled() {
        let coordinator = MeilingCoordinator.shared
        if coordinator.running { coordinator.stop() } else { coordinator.start() }
        UserDefaults.standard.set(coordinator.running, forKey: MeilingCoordinator.enabledKey)
    }

    @objc private func installInputMethod() {
        let message = MeilingInputMethodInstaller.install()
        let alert = NSAlert()
        alert.messageText = "Meyrin Input Method"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func showCaptions() { MeilingCaptionWindow.shared.show() }
    @objc private func fontUp() { MeilingCaptionWindow.shared.changeFont(by: 4) }
    @objc private func fontDown() { MeilingCaptionWindow.shared.changeFont(by: -4) }

    @objc private func ledTest() {
        let alert = NSAlert()
        alert.messageText = "Keyboard LED Ack"
        alert.informativeText = MeilingCoordinator.shared.ledSelfTest()
        alert.runModal()
    }
}
