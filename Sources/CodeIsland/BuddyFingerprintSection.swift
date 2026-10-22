import SwiftUI
import CodeIslandCore

/// Settings → Buddy section for one Atom with a fingerprint sensor.
struct BuddyFingerprintSection: View {
    @ObservedObject private var l10n = L10n.shared
    let channel: BuddyFingerprintChannel
    let buddyName: String
    @State private var manager: BuddyFingerprintManager
    @State private var confirmDeleteAll = false

    init(channel: BuddyFingerprintChannel, buddyName: String) {
        self.channel = channel
        self.buddyName = buddyName
        _manager = State(initialValue: BuddyFingerprintManager(channel: channel))
    }

    var body: some View {
        Section(String(format: l10n["fp_section_title"], buddyName)) {
            HStack {
                Text(l10n["fp_sensor"])
                Spacer()
                Circle()
                    .fill(channel.status?.present == true ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(sensorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if channel.attest != nil && !channel.keyMatches {
                Label(l10n["fp_key_mismatch"], systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if manager.slots.isEmpty {
                Text(l10n["fp_none_enrolled"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.slots, id: \.self) { slot in
                    HStack {
                        Image(systemName: "touchid")
                            .foregroundStyle(.secondary)
                        Text(String(format: l10n["fp_slot"], slot))
                        Spacer()
                        Button(role: .destructive) {
                            manager.delete(slot: slot)
                        } label: {
                            Text(l10n["fp_delete"])
                        }
                        .disabled(manager.isBusy)
                    }
                }
            }

            HStack(spacing: 8) {
                Group {
                    Button(l10n["fp_enroll"]) { manager.enroll(slot: nil) }
                    Button(l10n["fp_verify"]) { manager.verify() }
                    Button(l10n["fp_refresh"]) {
                        manager.refreshList()
                        channel.refreshStatus()
                    }
                }
                .disabled(manager.isBusy)
                Spacer()
                if manager.isBusy {
                    Button(l10n["fp_cancel"]) { manager.cancel() }
                } else {
                    Button(l10n["fp_delete_all"], role: .destructive) { confirmDeleteAll = true }
                        .disabled(manager.slots.isEmpty)
                }
            }
            .buttonStyle(.bordered)

            if let activity = activityText {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(activityIsFailure ? Color.red : Color.secondary)
            }
            if case .enrolling = manager.activity {
                Text(l10n["fp_enroll_hint"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { manager.refreshList() }
        .alert(l10n["fp_delete_all_confirm_title"], isPresented: $confirmDeleteAll) {
            Button(l10n["fp_delete_all"], role: .destructive) { manager.delete(slot: nil) }
            Button(l10n["fp_cancel"], role: .cancel) {}
        } message: {
            Text(l10n["fp_delete_all_confirm_body"])
        }
    }

    private var sensorText: String {
        guard let status = channel.status else { return l10n["fp_sensor_unknown"] }
        guard status.present else { return l10n["fp_sensor_missing"] }
        return String(format: l10n["fp_sensor_ready"], status.count ?? manager.slots.count)
    }

    private var activityIsFailure: Bool {
        if case .failed = manager.activity { return true }
        return false
    }

    private var activityText: String? {
        switch manager.activity {
        case .idle:
            return nil
        case .enrolling(let progress):
            guard let progress else { return l10n["fp_stage_place_first"] }
            switch progress.stage {
            case 1: return String(format: l10n["fp_stage_place"], Int(progress.sample) + 1)
            case 2: return l10n["fp_stage_lift"]
            case 3: return l10n["fp_stage_processing"]
            default: return l10n["fp_stage_saving"]
            }
        case .verifying: return l10n["fp_verifying"]
        case .deleting: return l10n["fp_deleting"]
        case .enrolled(let slot): return String(format: l10n["fp_enrolled_done"], slot)
        case .matched(let slot): return String(format: l10n["fp_matched"], slot)
        case .deleted(let slot):
            return slot.map { String(format: l10n["fp_deleted"], $0) } ?? l10n["fp_deleted_all"]
        case .failed(let result):
            return Self.failureText(result, l10n: l10n)
        }
    }

    static func failureText(_ result: BuddyFingerprintResult?, l10n: L10n) -> String {
        guard let result else { return l10n["fp_result_no_reply"] }
        switch result {
        case .busy: return l10n["fp_result_busy"]
        case .noSensor: return l10n["fp_result_no_sensor"]
        case .sensorError: return l10n["fp_result_sensor_error"]
        case .timeout: return l10n["fp_result_timeout"]
        case .cancelled: return l10n["fp_result_cancelled"]
        case .noMatch: return l10n["fp_result_no_match"]
        case .noBinding: return l10n["fp_result_no_binding"]
        case .duplicate: return l10n["fp_result_duplicate"]
        case .full: return l10n["fp_result_full"]
        case .invalid: return l10n["fp_result_invalid"]
        default: return String(format: l10n["fp_result_other"], Int(result.raw))
        }
    }
}
