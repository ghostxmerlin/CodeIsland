import AppKit

/// The status-item submenu "美玲": enable the key tap, install the input method, captions, LED bench.
@MainActor
final class MeilingMenu: NSObject, NSMenuDelegate {
    static let shared = MeilingMenu()
    let menu = NSMenu(title: "美玲")
    private let enabled = NSMenuItem(title: "启用（截取 Tab5 按键）", action: #selector(toggleEnabled), keyEquivalent: "")
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        menu.delegate = self
        enabled.target = self
        menu.addItem(enabled)
        menu.addItem(status)
        menu.addItem(.separator())
        add("安装美玲输入法", #selector(installInputMethod))
        add("显示字幕窗", #selector(showCaptions))
        add("字幕变大", #selector(fontUp))
        add("字幕变小", #selector(fontDown))
        menu.addItem(.separator())
        add("测试键盘指示灯回执", #selector(ledTest))
    }

    private func add(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let coordinator = MeilingCoordinator.shared
        enabled.state = coordinator.running ? .on : .off
        status.title = coordinator.lastError ?? (MeilingInputSwitcher.installed ? "美玲输入法：已启用" : "美玲输入法：未安装或未启用")
    }

    @objc private func toggleEnabled() {
        let coordinator = MeilingCoordinator.shared
        if coordinator.running { coordinator.stop() } else { coordinator.start() }
        UserDefaults.standard.set(coordinator.running, forKey: MeilingCoordinator.enabledKey)
    }

    @objc private func installInputMethod() {
        let message = MeilingInputMethodInstaller.install()
        let alert = NSAlert()
        alert.messageText = "美玲输入法"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func showCaptions() { MeilingCaptionWindow.shared.show() }
    @objc private func fontUp() { MeilingCaptionWindow.shared.changeFont(by: 4) }
    @objc private func fontDown() { MeilingCaptionWindow.shared.changeFont(by: -4) }

    @objc private func ledTest() {
        let alert = NSAlert()
        alert.messageText = "键盘指示灯回执"
        alert.informativeText = MeilingCoordinator.shared.ledSelfTest()
        alert.runModal()
    }
}
