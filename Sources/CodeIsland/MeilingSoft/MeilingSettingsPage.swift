import AppKit
import AVFoundation
import Combine
import MeilingSoftKit
import SwiftUI

/// Settings → Meyrin: the software mode (Mac-only dictation and meeting interpretation, MeilingSoftController),
/// its history and corrections, and the input method. The Tab5 hardware mode keeps its own "Meyrin (Tab5)" menu. The controllers are not observable, so the page
/// re-reads them every second. English only, like the rest of the 美玲 UI.
struct MeilingSettingsPage: View {
    @AppStorage(MeilingSoftHotkey.keyDefault) private var talkKey = 54
    @AppStorage(MeilingSoftController.allowSpeakerKey) private var allowSpeaker = false
    @State private var tick = 0
    @ObservedObject private var history = MeilingDictationHistory.shared
    @ObservedObject private var corrections = MeilingCorrectionStore.shared
    @State private var recording = false
    @State private var recordMonitor: Any?
    @State private var recordNote: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var soft: MeilingSoftController { MeilingSoftController.shared }

    var body: some View {
        let _ = tick
        Form {
            Section("Mac Dictation (no Tab5)") {
                Toggle("Mac Dictation", isOn: Binding(
                    get: { soft.enabled },
                    set: { on in
                        if on { soft.enable() } else { soft.disable() }
                        UserDefaults.standard.set(soft.enabled, forKey: MeilingSoftController.enabledKey)
                        tick += 1
                    }))
                HStack {
                    Text("Talk Key")
                    Spacer()
                    Text(recording ? "Press a key… (Esc to cancel)" : MeilingSoftHotkey.current.name)
                        .foregroundStyle(recording ? .orange : .primary)
                    Button(recording ? "Cancel" : "Record…") { recording ? stopRecording() : startRecording() }
                }
                if let recordNote { problem(recordNote) }
                Text("Any single modifier (left or right ⌘ ⌥ ⌃ ⇧), fn, or F1–F20 (on a MacBook keyboard, F-keys need fn or the standard function keys setting). Tap to latch, hold to talk. Esc or any shortcut cancels. Each sentence is typed at the cursor through the Meyrin input method.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Gemini API Key")
                    Spacer()
                    Text(MeilingSoftController.apiKey() == nil ? "Not set" : "Set")
                        .foregroundStyle(MeilingSoftController.apiKey() == nil ? .red : .secondary)
                    Button("Set…") { promptAPIKey(); tick += 1 }
                }
                if let error = soft.lastError { problem(error) }
                permissionRow("Input Monitoring", CGPreflightListenEventAccess(), "Privacy_ListenEvent")
                permissionRow("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
            }

            Section("Meeting Interpretation") {
                HStack {
                    Text(soft.meetingStarting ? "Starting…" : soft.meetingActive ? "On" : "Off")
                        .foregroundStyle(soft.meetingActive ? .green : .secondary)
                    Spacer()
                    Button(soft.meetingActive ? "Stop" : "Start") {
                        if soft.meetingActive { soft.stopMeeting() } else { soft.startMeeting() }
                        tick += 1
                    }
                    .disabled(!soft.enabled || soft.meetingStarting)
                }
                if !soft.enabled {
                    Text("Turn on Mac Dictation first: the meeting uses the same talk key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Passthrough (my own voice, untranslated)", isOn: Binding(
                    get: { soft.passthrough },
                    set: { _ in soft.togglePassthrough(); tick += 1 }))
                    .disabled(!soft.meetingActive)
                Toggle("Hear my translation in my headphones (monitor)", isOn: Binding(
                    get: { MeilingSoftController.monitorOn },
                    set: { soft.setMonitor($0); tick += 1 }))
                HStack {
                    Text("Virtual Mic")
                    Spacer()
                    Text(virtualMicStatus).foregroundStyle(.secondary)
                }
                Toggle("Allow on built-in speakers (echo risk)", isOn: $allowSpeaker)
                Button("Show Their Captions") { MeilingSoftCaptionWindow.theirs.show() }
            }

            Section("Dictation History") {
                MeilingHistoryView(history: history, limit: 5)
                HStack {
                    Text("Every sentence is kept on this Mac (last 1000), including ones that were not typed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show All…") { MeilingHistoryWindow.shared.show() }
                }
            }

            Section("Corrections") {
                if corrections.corrections.isEmpty {
                    Text("None yet. In the dictation history, click Edit on a misheard sentence and fix it: the corrected words are replaced automatically from then on, and lead the vocabulary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(corrections.corrections.sorted { $0.lastUsed > $1.lastUsed }) { c in
                    HStack {
                        Toggle(isOn: Binding(get: { c.enabled }, set: { corrections.setEnabled(c.id, $0) })) {
                            Text("\(c.heard)  →  \(c.right)")
                        }
                        Spacer()
                        Text(c.count == 1 ? "1 time" : "\(c.count) times").font(.caption).foregroundStyle(.secondary)
                        Button("Delete") { corrections.remove(c.id) }
                    }
                }
            }

            Section("Input Method") {
                HStack {
                    Text("Meyrin Input Method")
                    Spacer()
                    Text(MeilingInputSwitcher.installed ? "Enabled" : "Not installed or not enabled")
                        .foregroundStyle(MeilingInputSwitcher.installed ? .green : .red)
                    Button("Install…") { install() }
                }
            }

        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in tick += 1 }
        .onDisappear { stopRecording() }
    }

    // MARK: talk key recording

    private func startRecording() {
        recordNote = nil
        recording = true
        MeilingSoftHotkey.paused = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            record(event)
            return nil  // the key being recorded goes nowhere else
        }
    }

    private func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        recording = false
        MeilingSoftHotkey.paused = false
    }

    private func record(_ event: NSEvent) {
        let code = Int64(event.keyCode)
        if event.type == .keyDown, code == 53 {  // Esc
            stopRecording()
            return
        }
        guard let key = MeilingSoftHotkey.keys.first(where: { $0.keyCode == code }) else {
            if event.type == .keyDown {
                recordNote = "That key would also type: use a modifier, fn, or an F-key."
            }
            return
        }
        if key.isModifier {
            // flagsChanged also fires on release: take the key only when it goes down.
            let flags = UInt64(event.modifierFlags.rawValue)
            let pressed = key.deviceMask == 0 ? event.modifierFlags.contains(.function) : flags & key.deviceMask != 0
            guard event.type == .flagsChanged, pressed else { return }
        } else if event.type != .keyDown {
            return
        }
        talkKey = Int(key.keyCode)
        recordNote = nil
        stopRecording()
    }

    private func promptAPIKey() {
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
            self.alert("Could not save", error.localizedDescription)
        }
    }

    private var virtualMicStatus: String {
        if MeilingAudioDevices.find(uid: MeilingVirtualMic.defaultDeviceName) != nil {
            let name = MeilingAudioDevices.find(uid: MeilingVirtualMic.visibleMicUID)?.name ?? "Meyrin Virtual Mic"
            return name == "Meyrin Virtual Mic" ? name : "\(name) (old driver: run drivers/MeyrinMic/install.sh again)"
        }
        if MeilingAudioDevices.find(MeilingVirtualMic.fallbackDeviceName, output: true) != nil { return "BlackHole 2ch (fallback)" }
        return "Not installed (drivers/MeyrinMic)"
    }

    private func permissionRow(_ name: String, _ granted: Bool, _ pane: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(granted ? "Allowed" : "Not allowed").foregroundStyle(granted ? .green : .red)
            if !granted {
                Button("Open…") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func install() {
        alert("Meyrin Input Method", MeilingInputMethodInstaller.install())
        tick += 1
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
