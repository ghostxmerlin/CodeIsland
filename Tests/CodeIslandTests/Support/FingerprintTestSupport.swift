import Foundation
@testable import CodeIsland
import CodeIslandCore

func fpHex(_ string: String) -> Data {
    let digits = Array(string.filter { !$0.isWhitespace })
    return Data(stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(digits[$0...$0 + 1]), radix: 16)!
    })
}

/// Timers that only fire when a test says so.
@MainActor
final class FakeFingerprintClock {
    private struct Entry {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
    }

    private var entries: [Entry] = []

    var schedule: BuddyFingerprintSchedule {
        { [unowned self] delay, action in
            let index = entries.count
            entries.append(Entry(delay: delay, action: action))
            return { [weak self] in self?.entries[index].cancelled = true }
        }
    }

    /// Delays of timers still waiting to fire, oldest first.
    var pendingDelays: [TimeInterval] {
        entries.filter { !$0.cancelled }.map(\.delay)
    }

    /// Fire the oldest live timer.
    func fireNext() {
        guard let index = entries.firstIndex(where: { !$0.cancelled }) else { return }
        entries[index].cancelled = true
        entries[index].action()
    }
}

/// A channel wired to a frame recorder, with helpers to play Atom's side.
@MainActor
final class FingerprintChannelHarness {
    let clock = FakeFingerprintClock()
    var sent: [Data] = []
    private(set) var channel: BuddyFingerprintChannel!

    init(linkId: UUID = UUID()) {
        channel = BuddyFingerprintChannel(linkId: linkId, send: { [unowned self] in sent.append($0) },
                                          schedule: clock.schedule)
    }

    func receive(_ hex: String) {
        guard let frame = BuddyFingerprintFrame(payload: fpHex(hex)) else {
            fatalError("not a fingerprint frame: \(hex)")
        }
        channel.handle(frame)
    }

    /// Start the channel and answer the probe like current aism firmware.
    func startSupported(count: UInt8 = 5) {
        channel.start()
        let statusId = sent.last![2]
        receive(String(format: "d0 81 %02x 00 01 01 %02x 01 00", statusId, count))
        let attestId = sent.last![2]
        receive(String(format: "d0 c2 %02x 00 01 01 d9 df b1 6e ad 4e f7 db", attestId))
        sent.removeAll()
    }

    var lastReqId: UInt8 { sent.last![2] }
}
