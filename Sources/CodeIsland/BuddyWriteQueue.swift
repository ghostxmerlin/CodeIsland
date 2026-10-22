import Foundation
import CodeIslandCore

enum BuddyWritePriority: Int, Comparable {
    case auxiliary = 0
    case normal = 1
    case primary = 2
    case control = 3

    static func < (lhs: BuddyWritePriority, rhs: BuddyWritePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BuddyQueuedWrite: Equatable {
    let data: Data
    let priority: BuddyWritePriority
}

/// Pending BLE writes for one Buddy link.
///
/// `0xD0` fingerprint frames live in their own unbounded lane: they go out
/// first, in order, and are never dropped or merged. Everything else shares a
/// bounded lane that sends the highest priority first (oldest first within a
/// priority), replaces a queued frame of the same kind instead of piling up
/// another, and drops the lowest-priority oldest frame when full.
struct BuddyWriteQueue {
    private let capacity: Int
    private var fingerprintFrames: [BuddyQueuedWrite] = []
    private var frames: [BuddyQueuedWrite] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { fingerprintFrames.count + frames.count }
    var isEmpty: Bool { fingerprintFrames.isEmpty && frames.isEmpty }
    /// Fingerprint lane first, then the shared lane in arrival order.
    var contents: [BuddyQueuedWrite] { fingerprintFrames + frames }

    /// Queue `data` and return how many frames were dropped to make room.
    mutating func append(_ data: Data, priority: BuddyWritePriority) -> Int {
        let frame = BuddyQueuedWrite(data: data, priority: priority)
        if data.first == ESP32Protocol.fingerprintMarker {
            fingerprintFrames.append(frame)
            return 0
        }
        removeFramesSuperseded(by: data)
        frames.append(frame)
        var dropped = 0
        while frames.count > capacity {
            frames.remove(at: lowestPriorityOldestIndex())
            dropped += 1
        }
        return dropped
    }

    mutating func popNext() -> BuddyQueuedWrite? {
        if !fingerprintFrames.isEmpty {
            return fingerprintFrames.removeFirst()
        }
        guard !frames.isEmpty else { return nil }
        return frames.remove(at: highestPriorityOldestIndex())
    }

    mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        fingerprintFrames.removeAll(keepingCapacity: keepCapacity)
        frames.removeAll(keepingCapacity: keepCapacity)
    }

    private mutating func removeFramesSuperseded(by data: Data) {
        guard let marker = data.first else { return }
        // A new preview set or a tool-history clear makes every queued part
        // of the old one stale, not just the part at the same index.
        if (marker == ESP32Protocol.messagePreviewFrameMarker && data.count > 1 && data[data.startIndex + 1] == 0)
            || data == BuddyToolHistoryClearPayload().encode() {
            frames.removeAll { $0.data.first == marker }
            return
        }
        guard let key = Self.coalescingKey(for: data) else { return }
        frames.removeAll { Self.coalescingKey(for: $0.data) == key }
    }

    /// Frames with the same key carry the same slot of state, so only the
    /// newest needs sending. `nil` means the frame is never merged.
    static func coalescingKey(for data: Data) -> [UInt8]? {
        guard let marker = data.first else { return nil }
        switch marker {
        case ESP32Protocol.messagePreviewFrameMarker, ESP32Protocol.toolHistoryFrameMarker:
            // The tool-history clear shares entry 0's index; keep it apart.
            if data == BuddyToolHistoryClearPayload().encode() { return [marker] }
            guard data.count > 1 else { return nil }
            return [marker, data[data.startIndex + 1]]
        case ESP32Protocol.workspaceFrameMarker, ESP32Protocol.modelFrameMarker,
             ESP32Protocol.statsFrameMarker, ESP32Protocol.subagentFrameMarker,
             ESP32Protocol.timeHintFrameMarker, ESP32Protocol.brightnessFrameMarker,
             ESP32Protocol.orientationFrameMarker:
            return [marker]
        default:
            // Mascot state frames start with the mascot's slot.
            return MascotID(rawValue: marker) != nil ? [marker] : nil
        }
    }

    private func lowestPriorityOldestIndex() -> Int {
        var result = frames.startIndex
        for index in frames.indices.dropFirst() where frames[index].priority < frames[result].priority {
            result = index
        }
        return result
    }

    private func highestPriorityOldestIndex() -> Int {
        var result = frames.startIndex
        for index in frames.indices.dropFirst() where frames[index].priority > frames[result].priority {
            result = index
        }
        return result
    }
}
