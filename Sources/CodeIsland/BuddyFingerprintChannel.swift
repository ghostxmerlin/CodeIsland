import Foundation
import Observation
import os
import CodeIslandCore

/// Runs `action` after a delay and returns a closure that cancels it.
typealias BuddyFingerprintSchedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

enum BuddyFingerprintError: Error, Equatable {
    case timeout
    case disconnected
    case unsupported
    case rejected(BuddyFingerprintResult)
}

/// The fingerprint channel (`0xD0`) on one paired Buddy link.
///
/// Atom takes one request at a time, so requests wait here until the
/// previous reply arrives or times out; `CANCEL` skips the line. Events are
/// routed to the operation that started them by reqId, so a late event from
/// a cancelled round can't land in the next one.
@MainActor
@Observable
final class BuddyFingerprintChannel {
    enum Support: Equatable {
        case unknown
        case probing
        case supported
        case unsupported
    }

    typealias ReplyHandler = (Result<BuddyFingerprintReply, BuddyFingerprintError>) -> Void
    /// Gets every event of the operation, or `.failure(.disconnected)` if the
    /// link drops before a terminal event.
    typealias EventHandler = (Result<BuddyFingerprintEvent, BuddyFingerprintError>) -> Void

    static let replyTimeout: TimeInterval = 8
    /// Old firmware ignores `0xD0`; a STATUS that goes unanswered this long, twice, means no fingerprint support.
    static let probeTimeout: TimeInterval = 5

    private static let log = Logger(subsystem: "com.codeisland", category: "buddy-fingerprint")

    /// Owning `BuddyLink` id.
    let id: UUID
    private(set) var support: Support = .unknown
    private(set) var status: BuddyFingerprintStatus?
    private(set) var attest: BuddyFingerprintAttestStatus?

    var keyMatches: Bool {
        attest?.keyFingerprint == BuddyFingerprintAttestation.expectedKeyFingerprint
    }

    var canUnlock: Bool {
        support == .supported && keyMatches && attest?.hasFinger == true
    }

    private struct Pending {
        let op: BuddyFingerprintOp
        let reqId: UInt8
        let frames: [Data]
        var nextFrame = 0
        let timeout: TimeInterval
        /// Probe requests go out before support is known.
        let isProbe: Bool
        let onEvent: EventHandler?
        let completion: ReplyHandler
    }

    @ObservationIgnored private let sendFrame: (Data) -> Void
    @ObservationIgnored private let schedule: BuddyFingerprintSchedule
    @ObservationIgnored private var nextReqId: UInt8 = 1
    @ObservationIgnored private var inFlight: Pending?
    @ObservationIgnored private var cancelTimeout: (() -> Void)?
    @ObservationIgnored private var waiting: [Pending] = []
    @ObservationIgnored private var eventHandlers: [UInt8: EventHandler] = [:]

    init(linkId: UUID, send: @escaping (Data) -> Void, schedule: @escaping BuddyFingerprintSchedule) {
        id = linkId
        sendFrame = send
        self.schedule = schedule
    }

    // MARK: - Lifecycle

    /// Probe for fingerprint support: STATUS (retried once), then ATTEST_STATUS.
    func start() {
        guard support == .unknown else { return }
        support = .probing
        probe(attempt: 1)
    }

    private func probe(attempt: Int) {
        enqueue(op: .status, frames: nil, timeout: Self.probeTimeout, isProbe: true, onEvent: nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(.timeout) where attempt == 1:
                self.probe(attempt: 2)
            case .failure:
                Self.log.info("No fingerprint reply from Buddy; treating it as unsupported")
                self.support = .unsupported
                self.failWaiting(with: .unsupported)
            case .success(let reply):
                self.support = .supported
                self.status = BuddyFingerprintStatus(payload: reply.payload)
                self.refreshAttest()
            }
        }
    }

    /// Fail everything tied to the old connection.
    func connectionDropped() {
        cancelTimeout?()
        cancelTimeout = nil
        let pending = (inFlight.map { [$0] } ?? []) + waiting
        inFlight = nil
        waiting = []
        let handlers = eventHandlers.values
        eventHandlers = [:]
        pending.forEach { $0.completion(.failure(.disconnected)) }
        handlers.forEach { $0(.failure(.disconnected)) }
    }

    // MARK: - Requests

    func request(_ op: BuddyFingerprintOp, payload: Data = Data(),
                 onEvent: EventHandler? = nil, completion: @escaping ReplyHandler) {
        let frame = BuddyFingerprintRequest.encode(op: op, reqId: 0, payload: payload)
        enqueue(op: op, frames: [frame], timeout: Self.replyTimeout, isProbe: false, onEvent: onEvent, completion: completion)
    }

    func request(_ op: BuddyFingerprintOp, payload: Data = Data(),
                 onEvent: EventHandler? = nil) async -> Result<BuddyFingerprintReply, BuddyFingerprintError> {
        await withCheckedContinuation { continuation in
            request(op, payload: payload, onEvent: onEvent) { continuation.resume(returning: $0) }
        }
    }

    /// Re-read STATUS and ATTEST_STATUS, e.g. when an approval starts waiting.
    func refreshStatus() {
        guard support == .supported else { return }
        request(.status) { [weak self] result in
            if case .success(let reply) = result {
                self?.status = BuddyFingerprintStatus(payload: reply.payload)
            }
        }
        refreshAttest()
    }

    private func refreshAttest() {
        request(.attestStatus) { [weak self] result in
            if case .success(let reply) = result {
                self?.attest = BuddyFingerprintAttestStatus(payload: reply.payload)
            }
        }
    }

    /// Send both halves of the nonce under one reqId. Succeeds with that
    /// reqId once Atom is waiting for a finger.
    func startUnlock(nonce: Data, onEvent: @escaping EventHandler,
                     completion: @escaping (Result<UInt8, BuddyFingerprintError>) -> Void) {
        let frames = BuddyFingerprintRequest.unlockChallengeFrames(reqId: 0, nonce: nonce)
        enqueue(op: .unlockChallenge, frames: frames, timeout: Self.replyTimeout, isProbe: false, onEvent: onEvent) {
            completion($0.map(\.reqId))
        }
    }

    func startUnlock(nonce: Data, onEvent: @escaping EventHandler) async -> Result<UInt8, BuddyFingerprintError> {
        await withCheckedContinuation { continuation in
            startUnlock(nonce: nonce, onEvent: onEvent) { continuation.resume(returning: $0) }
        }
    }

    /// Stop whatever Atom is waiting a finger for. Sent right away; its reply
    /// isn't awaited, the cancelled operation ends with a `Cancelled` event.
    func cancel() {
        guard support == .supported else { return }
        sendFrame(BuddyFingerprintRequest.encode(op: .cancel, reqId: allocateReqId()))
    }

    // MARK: - Uplink

    func handle(_ frame: BuddyFingerprintFrame) {
        switch frame {
        case .reply(let reply):
            handleReply(reply)
        case .event(let event):
            guard let handler = eventHandlers[event.reqId] else {
                Self.log.debug("Dropping fingerprint event for unknown reqId \(event.reqId)")
                return
            }
            if event.isTerminal { eventHandlers[event.reqId] = nil }
            handler(.success(event))
        }
    }

    private func handleReply(_ reply: BuddyFingerprintReply) {
        guard var pending = inFlight, reply.reqId == pending.reqId, reply.rawOp == pending.op.rawValue else {
            Self.log.debug("Dropping fingerprint reply op \(reply.rawOp) reqId \(reply.reqId)")
            return
        }
        cancelTimeout?()
        cancelTimeout = nil
        guard reply.result == .ok else {
            finish(.failure(.rejected(reply.result)))
            return
        }
        pending.nextFrame += 1
        if pending.nextFrame < pending.frames.count {
            inFlight = pending
            transmit()
        } else {
            finish(.success(reply))
        }
    }

    // MARK: - Queue

    private func enqueue(op: BuddyFingerprintOp, frames: [Data]?, timeout: TimeInterval, isProbe: Bool,
                         onEvent: EventHandler?, completion: @escaping ReplyHandler) {
        if support == .unsupported && !isProbe {
            completion(.failure(.unsupported))
            return
        }
        let reqId = allocateReqId()
        let template = frames ?? [BuddyFingerprintRequest.encode(op: op, reqId: 0)]
        let stamped = template.map { frame -> Data in
            var frame = frame
            frame[frame.startIndex + 2] = reqId
            return frame
        }
        waiting.append(Pending(op: op, reqId: reqId, frames: stamped, timeout: timeout, isProbe: isProbe,
                               onEvent: onEvent, completion: completion))
        sendNextIfIdle()
    }

    private func sendNextIfIdle() {
        guard inFlight == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        if support == .unsupported && !next.isProbe {
            next.completion(.failure(.unsupported))
            sendNextIfIdle()
            return
        }
        if let onEvent = next.onEvent { eventHandlers[next.reqId] = onEvent }
        inFlight = next
        transmit()
    }

    private func transmit() {
        guard let pending = inFlight else { return }
        sendFrame(pending.frames[pending.nextFrame])
        cancelTimeout = schedule(pending.timeout) { [weak self] in
            guard let self, self.inFlight?.reqId == pending.reqId else { return }
            self.cancelTimeout = nil
            self.finish(.failure(.timeout))
        }
    }

    private func finish(_ result: Result<BuddyFingerprintReply, BuddyFingerprintError>) {
        guard let pending = inFlight else { return }
        inFlight = nil
        if case .failure = result { eventHandlers[pending.reqId] = nil }
        pending.completion(result)
        sendNextIfIdle()
    }

    private func failWaiting(with error: BuddyFingerprintError) {
        let failed = waiting
        waiting = []
        failed.forEach { $0.completion(.failure(error)) }
    }

    private func allocateReqId() -> UInt8 {
        let id = nextReqId
        nextReqId = nextReqId == 255 ? 1 : nextReqId + 1
        return id
    }
}
