import Foundation
import Observation
import CodeIslandCore

/// Settings-side state for managing the fingerprints on one Atom: enroll,
/// list, verify and delete over its fingerprint channel.
@MainActor
@Observable
final class BuddyFingerprintManager {
    enum Activity: Equatable {
        case idle
        /// `nil` until the first progress event arrives.
        case enrolling(BuddyEnrollProgress?)
        case verifying
        case deleting
        case enrolled(slot: Int)
        case matched(slot: Int)
        /// `nil` slot means every slot.
        case deleted(slot: Int?)
        /// `nil` when Atom never answered or the link dropped.
        case failed(BuddyFingerprintResult?)
    }

    private(set) var slots: [Int] = []
    private(set) var activity: Activity = .idle

    var isBusy: Bool {
        switch activity {
        case .enrolling, .verifying, .deleting: return true
        default: return false
        }
    }

    let channel: BuddyFingerprintChannel

    init(channel: BuddyFingerprintChannel) {
        self.channel = channel
    }

    func refreshList() {
        channel.request(.list) { [weak self] result in
            if case .success(let reply) = result {
                self?.slots = BuddyFingerprintSlots.slots(fromBitmap: reply.payload)
            }
        }
    }

    /// `slot` nil lets Atom pick the first free one.
    func enroll(slot: Int?) {
        activity = .enrolling(nil)
        channel.request(.enrollBegin, payload: BuddyFingerprintRequest.slotPayload(slot), onEvent: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let event) where event.result == .ok:
                guard let progress = BuddyEnrollProgress(eventData: event.data) else { return }
                if progress.stage == BuddyEnrollProgress.doneStage {
                    self.activity = .enrolled(slot: progress.slot)
                    self.afterSlotsChanged()
                } else {
                    self.activity = .enrolling(progress)
                }
            case .success(let event):
                self.activity = .failed(event.result)
            case .failure:
                self.activity = .failed(nil)
            }
        }, completion: failOnReplyError)
    }

    func verify() {
        activity = .verifying
        channel.request(.verify, onEvent: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let event) where event.result == .ok:
                if let slot = BuddyFingerprintEvent.verifySlot(eventData: event.data) {
                    self.activity = .matched(slot: slot)
                } else {
                    self.activity = .failed(.noMatch)
                }
            case .success(let event):
                self.activity = .failed(event.result)
            case .failure:
                self.activity = .failed(nil)
            }
        }, completion: failOnReplyError)
    }

    /// `slot` nil deletes every fingerprint; Atom doesn't ask to confirm.
    func delete(slot: Int?) {
        activity = .deleting
        channel.request(.delete, payload: BuddyFingerprintRequest.slotPayload(slot)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.activity = .deleted(slot: slot)
                self.afterSlotsChanged()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    /// The cancelled operation ends through its own `Cancelled` event.
    func cancel() {
        channel.cancel()
    }

    private var failOnReplyError: BuddyFingerprintChannel.ReplyHandler {
        { [weak self] result in
            if case .failure(let error) = result { self?.fail(error) }
        }
    }

    private func fail(_ error: BuddyFingerprintError) {
        if case .rejected(let result) = error {
            activity = .failed(result)
        } else {
            activity = .failed(nil)
        }
    }

    private func afterSlotsChanged() {
        refreshList()
        // The enrolled count feeds the approval hint.
        channel.refreshStatus()
    }
}
