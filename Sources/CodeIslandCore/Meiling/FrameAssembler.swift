import Foundation

public enum MeilingAssemblerEvent: Equatable, Sendable {
    /// Held keycodes to re-post unchanged (a lone marker or a broken open sequence).
    case passThrough([UInt16])
    /// The marker triple arrived; the coordinator acks (caption at once, dictation once the input method is active).
    /// Only marker keys come before the ack, so a blind Mac never types a letter (review C1).
    case opened(MeilingFrameKind)
    case completed(MeilingFrameKind, seq: UInt16, text: String)
    /// "gap" (Tab5 gone quiet), "stray" (another key), "crc", "short" (closed without payload: no ack), "version".
    case failed(MeilingFrameKind?, reason: String)
}

/// Turns key-downs into 美玲 frames. Not thread-safe: feed it from the event-tap thread only.
public final class MeilingFrameAssembler {
    /// The open sequence must complete within this window (USB sends it in ~6 ms, BLE in ~50 ms).
    public static let openWindowMs: UInt64 = 150
    /// Inside a frame: the longest pause between keys, and the longer one allowed while the Tab5 waits for our ack.
    public static let gapMs: UInt64 = 300, ackGapMs: UInt64 = 1000

    private enum State {
        case idle
        case opening(held: [UInt16], since: UInt64)
        /// Opened and acked or about to be: version + seq (3 symbols) come first after the ack.
        case body(MeilingFrameKind, symbols: [UInt8], closing: Bool, waitingAck: Bool)
        /// An aborted frame: the Tab5 does not know and keeps sending; swallow its keys until F15 F15 or 300 ms of
        /// quiet (review C2). A user's letter in this window is swallowed too.
        case draining(closing: Bool)
    }

    private var state = State.idle
    private var lastKeyMs: UInt64 = 0

    public init() {}

    public var inFrame: Bool {
        if case .idle = state { return false }
        return true
    }

    private func isFrameKey(_ keyCode: UInt16) -> Bool {
        keyCode == MeilingKeyCodec.f15 || MeilingKeyCodec.symbol(forKeyCode: keyCode) != nil
    }

    public func keyDown(_ keyCode: UInt16, atMs now: UInt64) -> (swallow: Bool, events: [MeilingAssemblerEvent]) {
        var events = tick(atMs: now)
        lastKeyMs = now
        switch state {
        case .idle:
            if keyCode == MeilingKeyCodec.f13 || keyCode == MeilingKeyCodec.f14 {
                state = .opening(held: [keyCode], since: now)
                return (true, events)
            }
            return (false, events)

        case let .opening(held, since):
            let expected = held.count == 1 ? MeilingKeyCodec.f15 : held[0]
            if keyCode == expected && now - since <= Self.openWindowMs {
                if held.count == 2 {
                    let kind: MeilingFrameKind = held[0] == MeilingKeyCodec.f13 ? .dictation : .caption
                    state = .body(kind, symbols: [], closing: false, waitingAck: true)
                    return (true, events + [.opened(kind)])
                }
                state = .opening(held: held + [keyCode], since: since)
                return (true, events)
            }
            state = .idle
            events.append(.passThrough(held))
            let rest = keyDown(keyCode, atMs: now)
            lastKeyMs = now
            return (rest.swallow, events + rest.events)

        case let .body(kind, symbols, closing, _):
            if keyCode == MeilingKeyCodec.f15 {
                if !closing {
                    state = .body(kind, symbols: symbols, closing: true, waitingAck: false)
                    return (true, events)
                }
                state = .idle
                return (true, events + [finish(kind, symbols: symbols)])
            }
            guard !closing, let symbol = MeilingKeyCodec.symbol(forKeyCode: keyCode) else {
                state = .draining(closing: false)
                return (false, events + [.failed(kind, reason: "stray")])  // the user's own key reaches the app
            }
            if symbols.isEmpty && symbol != 0 {
                state = .draining(closing: false)
                return (true, events + [.failed(kind, reason: "version")])
            }
            state = .body(kind, symbols: symbols + [symbol], closing: false, waitingAck: false)
            return (true, events)

        case let .draining(closing):
            if keyCode == MeilingKeyCodec.f15 {
                state = closing ? .idle : .draining(closing: true)
                return (true, events)
            }
            if MeilingKeyCodec.symbol(forKeyCode: keyCode) != nil {
                state = .draining(closing: false)
                return (true, events)
            }
            state = .idle  // a key the Tab5 never sends: the frame is over, let it through
            let rest = keyDown(keyCode, atMs: now)
            return (rest.swallow, events + rest.events)
        }
    }

    public func tick(atMs now: UInt64) -> [MeilingAssemblerEvent] {
        switch state {
        case .idle:
            return []
        case let .opening(held, since):
            guard now - since > Self.openWindowMs else { return [] }
            state = .idle
            return [.passThrough(held)]
        case let .body(kind, _, _, waitingAck):
            guard now - lastKeyMs > (waitingAck ? Self.ackGapMs : Self.gapMs) else { return [] }
            state = .draining(closing: false)
            lastKeyMs = now  // the drain's quiet period starts at the abort
            return [.failed(kind, reason: "gap")]
        case .draining:
            if now - lastKeyMs > Self.gapMs { state = .idle }
            return []
        }
    }

    private func finish(_ kind: MeilingFrameKind, symbols: [UInt8]) -> MeilingAssemblerEvent {
        guard symbols.count >= 7 else { return .failed(kind, reason: "short") }  // version + seq + crc
        let seq = UInt16(symbols[1]) << 5 | UInt16(symbols[2])
        let payload = Array(symbols[3..<(symbols.count - 4)])
        let c = symbols.suffix(4).map(UInt16.init)
        let crc = c[0] << 15 | c[1] << 10 | c[2] << 5 | c[3]
        guard let text = MeilingKeyCodec.decodePayload(payload),
              MeilingKeyCodec.crc16(Array(text.utf8)) == crc else { return .failed(kind, reason: "crc") }
        return .completed(kind, seq: seq, text: text)
    }
}
