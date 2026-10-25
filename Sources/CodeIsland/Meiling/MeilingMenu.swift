import AppKit

/// The status-item submenu "美玲": enable the key tap, install the input method, captions, LED bench.
@MainActor
final class MeilingMenu: NSObject, NSMenuDelegate {
    static let shared = MeilingMenu()
    let menu = NSMenu(title: "Meyrin")
    private let enabled = NSMenuItem(title: "Enable (capture Tab5 keys)", action: #selector(toggleEnabled), keyEquivalent: "")
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Mac-only 美玲 (MeilingSoftController): no Tab5 needed.
    private let softEnabled = NSMenuItem(title: "", action: #selector(toggleSoft), keyEquivalent: "")
    private let softStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let meeting = NSMenuItem(title: "", action: #selector(toggleMeeting), keyEquivalent: "")
    private let passthrough = NSMenuItem(title: "Passthrough (my own voice, untranslated)", action: #selector(togglePassthrough), keyEquivalent: "")
    private let talkKeyMenu = NSMenu(title: "Talk Key")

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
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Mac Only (no Tab5)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in [softEnabled, meeting, passthrough] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(softStatus)
        for key in MeilingSoftHotkey.keys where key.isModifier {  // F-keys: record them in Settings → Meyrin
            let item = NSMenuItem(title: key.name, action: #selector(pickTalkKey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(key.keyCode)
            talkKeyMenu.addItem(item)
        }
        let talkKey = NSMenuItem(title: "Talk Key", action: nil, keyEquivalent: "")
        talkKey.submenu = talkKeyMenu
        menu.addItem(talkKey)
        add("Set Gemini API Key…", #selector(setAPIKey))
        add("Show Their Captions", #selector(showTheirCaptions))
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
        let soft = MeilingSoftController.shared
        let key = MeilingSoftHotkey.current.name
        softEnabled.title = "Mac Dictation (\(key): tap to latch / hold to talk)"
        softEnabled.state = soft.enabled ? .on : .off
        meeting.title = soft.meetingStarting ? "Meeting Interpretation: starting…" : (soft.meetingActive ? "Stop Meeting Interpretation" : "Start Meeting Interpretation (virtual mic)")
        meeting.isEnabled = soft.enabled && !soft.meetingStarting
        passthrough.isEnabled = soft.meetingActive
        passthrough.state = soft.passthrough ? .on : .off
        softStatus.title = soft.lastError ?? (MeilingSoftController.apiKey() == nil ? "Gemini API key: not set" : "Gemini API key: set")
        for item in talkKeyMenu.items { item.state = Int64(item.tag) == MeilingSoftHotkey.current.keyCode ? .on : .off }
    }

    @objc private func toggleSoft() {
        let soft = MeilingSoftController.shared
        if soft.enabled { soft.disable() } else { soft.enable() }
        UserDefaults.standard.set(soft.enabled, forKey: MeilingSoftController.enabledKey)
    }

    @objc private func toggleMeeting() {
        let soft = MeilingSoftController.shared
        if soft.meetingActive { soft.stopMeeting() } else { soft.startMeeting() }
    }

    @objc private func togglePassthrough() { MeilingSoftController.shared.togglePassthrough() }

    @objc private func pickTalkKey(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: MeilingSoftHotkey.keyDefault)
    }

    @objc private func showTheirCaptions() { MeilingCaptionWindow.theirs.show() }

    @objc private func setAPIKey() { Self.promptAPIKey() }

    /// Asks for the Gemini API key and saves it (also used by the Meyrin settings page).
    static func promptAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API Key"
        alert.informativeText = "Saved in \(MeilingSoftController.keyFile.path) (readable only by you)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do { try MeilingSoftController.saveAPIKey(key) } catch {
            let failed = NSAlert()
            failed.messageText = "Could not save: \(error.localizedDescription)"
            failed.runModal()
        }
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
