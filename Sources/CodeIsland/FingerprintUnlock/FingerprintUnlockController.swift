import Foundation
import Observation
import os
import CodeIslandCore

/// What the controller needs from the Mac: the setting, permissions, the
/// lock state, the stored password and the keyboard.
@MainActor
protocol FingerprintUnlockSystem: AnyObject {
    var isEnabled: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    func lockState() -> Bool?
    func hasPassword() -> Bool
    /// The caller zeroes the returned bytes.
    func readPassword() throws -> Data
    func typePassword(_ password: Data) throws
    func now() -> TimeInterval
}

/// An Atom that can answer unlock challenges.
@MainActor
protocol FingerprintUnlockDevice: AnyObject {
    var id: UUID { get }
    var canUnlock: Bool { get }
    func startUnlock(nonce: Data, onEvent: @escaping BuddyFingerprintChannel.EventHandler,
                     completion: @escaping (Result<UInt8, BuddyFingerprintError>) -> Void)
    func cancel()
}

extension BuddyFingerprintChannel: FingerprintUnlockDevice {}

/// Unlocks the lock screen after a fingerprint match on Atom: one round per
/// lock, a fresh nonce per round, the tag checked here, and the password
/// typed at most once. Anything off along the way types nothing.
@MainActor
@Observable
final class FingerprintUnlockController {
    enum StopReason: Equatable {
        case unlockedElsewhere
        case lockStateUnknown
        case tagInvalid
        case fingerprintFailed(BuddyFingerprintResult)
        case deviceLost
        case passwordUnavailable
        case typingRefused(LockScreenRefusal)
        /// The password went in but the screen stayed locked.
        case notConfirmed
        case sleep
        case disabled
    }

    enum Phase: Equatable {
        case idle
        case waitingForFinger(noMatch: Bool)
        case submitting
        case unlocked
        case stopped(StopReason)
    }

    static let confirmSeconds: TimeInterval = 8

    private static let log = Logger(subsystem: "com.codeisland", category: "fingerprint-unlock")

    private(set) var phase: Phase = .idle

    /// A challenge sent to one device. `open` while Atom is still waiting
    /// for a finger on it, so stopping knows whether to send CANCEL.
    private struct Round {
        let token: Int
        let nonce: Data
        weak var device: FingerprintUnlockDevice?
        var open = true
    }

    @ObservationIgnored private let system: FingerprintUnlockSystem
    @ObservationIgnored private let device: () -> FingerprintUnlockDevice?
    @ObservationIgnored private var gate = FingerprintUnlockGate()
    @ObservationIgnored private var armedThisLock = false
    @ObservationIgnored private var verified = false
    @ObservationIgnored private var round: Round?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var submitDeadline: TimeInterval?

    /// True while a round or a submission needs the lock state polled.
    var isBusy: Bool { gate.active || submitDeadline != nil }

    init(system: FingerprintUnlockSystem, device: @escaping () -> FingerprintUnlockDevice?) {
        self.system = system
        self.device = device
    }

    // MARK: - Driving

    /// Call every 0.25 s while the screen may be locked.
    func tick() {
        let locked = system.lockState()
        if let deadline = submitDeadline {
            if locked == false {
                submitDeadline = nil
                armedThisLock = false
                phase = .unlocked
                Self.log.info("Fingerprint unlock confirmed")
            } else if system.now() >= deadline {
                submitDeadline = nil
                phase = .stopped(.notConfirmed)
                Self.log.info("Screen still locked after submitting; not retrying")
            }
            return
        }
        guard system.isEnabled else { return }

        if locked == false {
            armedThisLock = false
        } else if locked == true, !gate.active, !armedThisLock, preconditionsMet() {
            // Not latched while something is missing: e.g. ATTEST_STATUS may
            // still be on its way right after a reconnect.
            armedThisLock = true
            verified = false
            gate.arm()
        }

        switch gate.step(locked: locked, verified: verified) {
        case .wait:
            break
        case .challenge:
            challenge()
        case .stop:
            endRound(locked == nil ? .lockStateUnknown : .unlockedElsewhere)
        case .fire:
            submit()
        }
    }

    func screenDidWake() {
        stopForNewAttempt()
    }

    /// The old link's round is gone; let the reconnected one start fresh.
    func deviceDidReconnect() {
        stopForNewAttempt()
    }

    func systemWillSleep() {
        gate.cancel()
        endRound(.sleep)
    }

    func settingDidTurnOff() {
        gate.cancel()
        submitDeadline = nil
        endRound(.disabled)
    }

    // MARK: - Round

    private func preconditionsMet() -> Bool {
        system.isAccessibilityTrusted && system.hasPassword() && device()?.canUnlock == true
    }

    private func challenge() {
        guard let target = device(), target.canUnlock else {
            gate.fail()
            phase = .stopped(.deviceLost)
            return
        }
        nextToken += 1
        let token = nextToken
        let nonce = BuddyFingerprintAttestation.makeNonce()
        round = Round(token: token, nonce: nonce, device: target)
        phase = .waitingForFinger(noMatch: false)
        Self.log.info("Screen locked; sending an unlock challenge to Atom")
        target.startUnlock(nonce: nonce, onEvent: { [weak self] result in
            self?.handle(result, token: token)
        }, completion: { [weak self] result in
            guard let self, self.round?.token == token, case .failure(let error) = result else { return }
            self.round?.open = false
            self.gate.fail()
            self.endRound(Self.reason(for: error))
        })
    }

    private func handle(_ result: Result<BuddyFingerprintEvent, BuddyFingerprintError>, token: Int) {
        guard let current = round, current.token == token else { return }
        switch result {
        case .failure(let error):
            round?.open = false
            gate.fail()
            endRound(Self.reason(for: error))
        case .success(let event) where event.result == .noMatch:
            phase = .waitingForFinger(noMatch: true)
        case .success(let event) where event.result == .ok:
            round?.open = false
            if BuddyFingerprintAttestation.verify(tag: event.data, nonce: current.nonce) {
                verified = true
                tick()
            } else {
                Self.log.error("Atom's unlock tag did not verify; not typing")
                gate.fail()
                endRound(.tagInvalid)
            }
        case .success(let event):
            round?.open = false
            gate.fail()
            endRound(.fingerprintFailed(event.result))
        }
    }

    private func submit() {
        // A nonce is good for one answer; this round is over either way.
        round = nil
        verified = false
        var password: Data
        do {
            password = try system.readPassword()
        } catch {
            phase = .stopped(.passwordUnavailable)
            return
        }
        defer { password.resetBytes(in: 0..<password.count) }
        do {
            try system.typePassword(password)
        } catch let refusal as LockScreenRefusal {
            Self.log.info("Not typing the password: \(String(describing: refusal))")
            phase = .stopped(.typingRefused(refusal))
            return
        } catch {
            phase = .stopped(.typingRefused(.eventCreationFailed))
            return
        }
        submitDeadline = system.now() + Self.confirmSeconds
        phase = .submitting
    }

    /// Forget the round, telling Atom to stop waiting if it still is.
    private func endRound(_ reason: StopReason) {
        if let current = round {
            if current.open { current.device?.cancel() }
            round = nil
        }
        verified = false
        phase = .stopped(reason)
    }

    private func stopForNewAttempt() {
        if let current = round {
            if current.open { current.device?.cancel() }
            round = nil
        }
        gate.cancel()
        verified = false
        armedThisLock = false
    }

    private static func reason(for error: BuddyFingerprintError) -> StopReason {
        if case .rejected(let result) = error { return .fingerprintFailed(result) }
        return .deviceLost
    }
}
