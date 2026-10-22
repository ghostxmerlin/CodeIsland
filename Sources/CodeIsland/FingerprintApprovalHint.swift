import CodeIslandCore

/// What the approval card says about approving on Atom. Atom only sends
/// approve (`F0`) after a fingerprint match; its button can only deny.
enum FingerprintApprovalHint: Equatable {
    case pressFingerOnAtom
    case approveOnMac

    /// `statuses` holds the last STATUS of every Buddy that speaks the
    /// fingerprint channel; no such Buddy means no hint at all.
    static func resolve(_ statuses: [BuddyFingerprintStatus?]) -> FingerprintApprovalHint? {
        guard !statuses.isEmpty else { return nil }
        let ready = statuses.contains { status in
            guard let status else { return false }
            return status.present && (status.count ?? 0) > 0
        }
        return ready ? .pressFingerOnAtom : .approveOnMac
    }

    var l10nKey: String {
        switch self {
        case .pressFingerOnAtom: return "fp_approve_hint_finger"
        case .approveOnMac: return "fp_approve_hint_mac"
        }
    }
}
