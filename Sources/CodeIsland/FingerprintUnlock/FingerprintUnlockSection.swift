import AppKit
import ApplicationServices
import SwiftUI
import CodeIslandCore

/// Settings → Buddy section for phase-1 lock-screen unlock. Off by default;
/// turning it on goes through a warning, because the key is public.
struct FingerprintUnlockSection: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.fingerprintUnlockEnabled) private var enabled = SettingsDefaults.fingerprintUnlockEnabled
    @State private var confirmEnable = false
    @State private var password = ""
    @State private var hasPassword = false
    @State private var axTrusted = false
    @State private var passwordError: String?

    private var bridge: ESP32BridgeManager { ESP32BridgeManager.shared }
    private var controller: FingerprintUnlockController { FingerprintUnlockService.shared.controller }

    var body: some View {
        Section(l10n["fp_unlock_section"]) {
            Toggle(l10n["fp_unlock_toggle"], isOn: Binding(
                get: { enabled },
                set: { turnOn in
                    if turnOn { confirmEnable = true } else { enabled = false }
                }
            ))

            Label(l10n["fp_unlock_warning"], systemImage: "exclamationmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            HStack {
                Text(l10n["fp_unlock_ax"])
                Spacer()
                if axTrusted {
                    Text(l10n["fp_unlock_ax_allowed"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(l10n["fp_unlock_ax_grant"]) {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        axTrusted = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }

            HStack {
                Text(l10n["fp_unlock_password"])
                Spacer()
                Text(hasPassword ? l10n["fp_unlock_password_saved"] : l10n["fp_unlock_password_not_saved"])
                    .font(.caption)
                    .foregroundStyle(hasPassword ? Color.secondary : Color.orange)
            }
            HStack {
                SecureField(l10n["fp_unlock_password_placeholder"], text: $password)
                    .textFieldStyle(.roundedBorder)
                Button(l10n["fp_unlock_save"]) { savePassword() }
                    .disabled(password.isEmpty)
                Button(l10n["fp_unlock_delete_password"], role: .destructive) { deletePassword() }
                    .disabled(!hasPassword)
            }
            if let passwordError {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(l10n["fp_unlock_password_note"])
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(l10n["fp_unlock_atom"])
                Spacer()
                Text(atomText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enabled {
                HStack {
                    Text(l10n["fp_unlock_state"])
                    Spacer()
                    Text(phaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .alert(l10n["fp_unlock_confirm_title"], isPresented: $confirmEnable) {
            Button(l10n["fp_unlock_confirm_enable"], role: .destructive) { enabled = true }
            Button(l10n["fp_cancel"], role: .cancel) {}
        } message: {
            Text(l10n["fp_unlock_warning"])
        }
    }

    private func refresh() {
        axTrusted = AXIsProcessTrusted()
        hasPassword = UnlockPasswordStore.hasPassword()
    }

    private func savePassword() {
        do {
            try UnlockPasswordStore.save(password)
            passwordError = nil
        } catch {
            passwordError = String(format: l10n["fp_unlock_save_failed"], Self.status(of: error))
        }
        password = ""
        hasPassword = UnlockPasswordStore.hasPassword()
    }

    private func deletePassword() {
        do {
            try UnlockPasswordStore.delete()
            passwordError = nil
        } catch {
            passwordError = String(format: l10n["fp_unlock_save_failed"], Self.status(of: error))
        }
        hasPassword = UnlockPasswordStore.hasPassword()
    }

    private static func status(of error: Error) -> Int {
        if case UnlockPasswordStoreError.keychain(let status) = error { return Int(status) }
        return 0
    }

    private var atomText: String {
        let channels = bridge.fingerprintChannels
        if channels.contains(where: \.canUnlock) { return l10n["fp_unlock_atom_ready"] }
        if channels.isEmpty { return l10n["fp_unlock_atom_none"] }
        if !channels.contains(where: \.keyMatches) { return l10n["fp_unlock_atom_key_mismatch"] }
        return l10n["fp_unlock_atom_no_finger"]
    }

    private var phaseText: String {
        switch controller.phase {
        case .idle: return l10n["fp_unlock_phase_idle"]
        case .waitingForFinger(let noMatch):
            return noMatch ? l10n["fp_unlock_phase_no_match"] : l10n["fp_unlock_phase_waiting"]
        case .submitting: return l10n["fp_unlock_phase_submitting"]
        case .unlocked: return l10n["fp_unlock_phase_unlocked"]
        case .stopped(let reason): return stopText(reason)
        }
    }

    private func stopText(_ reason: FingerprintUnlockController.StopReason) -> String {
        switch reason {
        case .unlockedElsewhere: return l10n["fp_unlock_stop_elsewhere"]
        case .lockStateUnknown: return l10n["fp_unlock_stop_unknown"]
        case .tagInvalid: return l10n["fp_unlock_stop_tag"]
        case .fingerprintFailed(let result):
            return String(format: l10n["fp_unlock_stop_failed"], BuddyFingerprintSection.failureText(result, l10n: l10n))
        case .deviceLost: return l10n["fp_unlock_stop_device"]
        case .passwordUnavailable: return l10n["fp_unlock_stop_password"]
        case .typingRefused(.noVisibleWindow): return l10n["fp_unlock_stop_window"]
        case .typingRefused: return l10n["fp_unlock_stop_typing"]
        case .notConfirmed: return l10n["fp_unlock_stop_unconfirmed"]
        case .sleep: return l10n["fp_unlock_stop_sleep"]
        case .disabled: return l10n["fp_unlock_stop_disabled"]
        }
    }
}
