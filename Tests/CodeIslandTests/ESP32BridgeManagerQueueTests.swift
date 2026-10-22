import XCTest
@testable import CodeIsland

final class ESP32BridgeManagerQueueTests: XCTestCase {
    func testWriteQueueDropsOldAuxiliaryFramesBeforePrimaryFrames() {
        var queue = BuddyWriteQueue(capacity: 3)

        XCTAssertEqual(queue.append(Data([0xFB, 0]), priority: .auxiliary), 0)
        XCTAssertEqual(queue.append(Data([0xFB, 1]), priority: .auxiliary), 0)
        XCTAssertEqual(queue.append(Data([0x01]), priority: .primary), 0)
        XCTAssertEqual(queue.append(Data([0x02]), priority: .primary), 1)

        XCTAssertEqual(queue.contents.map(\.data), [
            Data([0xFB, 1]),
            Data([0x01]),
            Data([0x02]),
        ])
    }

    func testWriteQueueDropsNewAuxiliaryFrameWhenExistingFramesAreMoreImportant() {
        var queue = BuddyWriteQueue(capacity: 3)

        XCTAssertEqual(queue.append(Data([0x01]), priority: .primary), 0)
        XCTAssertEqual(queue.append(Data([0x02]), priority: .primary), 0)
        XCTAssertEqual(queue.append(Data([0xF7, 1]), priority: .control), 0)
        XCTAssertEqual(queue.append(Data([0xFB, 0]), priority: .auxiliary), 1)

        XCTAssertEqual(queue.contents.map(\.data), [
            Data([0x01]),
            Data([0x02]),
            Data([0xF7, 1]),
        ])
    }

    func testWriteQueueSendsHigherPriorityFirst() {
        var queue = BuddyWriteQueue(capacity: 3)

        _ = queue.append(Data([0xFB, 0]), priority: .auxiliary)
        _ = queue.append(Data([0x01]), priority: .primary)
        _ = queue.append(Data([0xFD, 1]), priority: .control)

        XCTAssertEqual(queue.popNext()?.data, Data([0xFD, 1]))
        XCTAssertEqual(queue.popNext()?.data, Data([0x01]))
        XCTAssertEqual(queue.popNext()?.data, Data([0xFB, 0]))
        XCTAssertNil(queue.popNext())
    }

    func testSamePriorityFramesKeepTheirOrder() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xFC, 1]), priority: .normal)
        _ = queue.append(Data([0xF9, 1]), priority: .normal)
        _ = queue.append(Data([0xFA, 1]), priority: .normal)

        XCTAssertEqual(queue.popNext()?.data, Data([0xFC, 1]))
        XCTAssertEqual(queue.popNext()?.data, Data([0xF9, 1]))
        XCTAssertEqual(queue.popNext()?.data, Data([0xFA, 1]))
    }

    func testFingerprintFramesAreNeverDropped() {
        var queue = BuddyWriteQueue(capacity: 3)

        for value in UInt8(0)..<3 {
            XCTAssertEqual(queue.append(Data([0xF7, value]), priority: .control), 0)
        }
        for reqId in UInt8(1)...5 {
            XCTAssertEqual(queue.append(Data([0xD0, 0x01, reqId]), priority: .auxiliary), 0)
        }

        XCTAssertEqual(queue.count, 8)
    }

    func testFingerprintFramesGoFirstInOrder() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0x01]), priority: .primary)
        _ = queue.append(Data([0xFB, 0]), priority: .auxiliary)
        _ = queue.append(Data([0xD0, 0x43, 1, 0x00]), priority: .control)
        _ = queue.append(Data([0xD0, 0x43, 1, 0x10]), priority: .control)

        XCTAssertEqual(queue.popNext()?.data, Data([0xD0, 0x43, 1, 0x00]))
        XCTAssertEqual(queue.popNext()?.data, Data([0xD0, 0x43, 1, 0x10]))
        XCTAssertEqual(queue.popNext()?.data, Data([0x01]))
        XCTAssertEqual(queue.contents.map(\.data), [Data([0xFB, 0])])
    }

    func testSameKindFrameReplacesQueuedOne() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xFC, 1, 0x61]), priority: .normal)
        _ = queue.append(Data([0xFC, 1, 0x62]), priority: .normal)

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.popNext()?.data, Data([0xFC, 1, 0x62]))
    }

    func testStateFramesCoalescePerMascot() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0x00, 1]), priority: .primary)
        _ = queue.append(Data([0x01, 1]), priority: .primary)
        _ = queue.append(Data([0x00, 2]), priority: .primary)

        XCTAssertEqual(queue.contents.map(\.data), [Data([0x01, 1]), Data([0x00, 2])])
    }

    func testCoalescedFrameMovesToTheBack() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xFC, 1]), priority: .normal)
        _ = queue.append(Data([0xF9, 1]), priority: .normal)
        _ = queue.append(Data([0xFC, 2]), priority: .normal)

        XCTAssertEqual(queue.contents.map(\.data), [Data([0xF9, 1]), Data([0xFC, 2])])
    }

    func testPreviewAndToolHistoryCoalescePerIndex() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xFB, 1, 3, 0x01, 0x61]), priority: .auxiliary)
        _ = queue.append(Data([0xFB, 1, 3, 0x01, 0x62]), priority: .auxiliary)
        _ = queue.append(Data([0xFB, 2, 3, 0x01, 0x63]), priority: .auxiliary)
        _ = queue.append(Data([0xF5, 1, 0x81, 0x61]), priority: .auxiliary)
        _ = queue.append(Data([0xF5, 1, 0x81, 0x62]), priority: .auxiliary)
        _ = queue.append(Data([0xF5, 2, 0x81, 0x63]), priority: .auxiliary)

        XCTAssertEqual(queue.contents.map(\.data), [
            Data([0xFB, 1, 3, 0x01, 0x62]),
            Data([0xFB, 2, 3, 0x01, 0x63]),
            Data([0xF5, 1, 0x81, 0x62]),
            Data([0xF5, 2, 0x81, 0x63]),
        ])
    }

    func testNewPreviewSetDropsOldParts() {
        var queue = BuddyWriteQueue(capacity: 8)

        for index in UInt8(0)..<3 {
            _ = queue.append(Data([0xFB, index, 3, 0x01, 0x61]), priority: .auxiliary)
        }
        _ = queue.append(Data([0xFB, 0, 2, 0x01, 0x62]), priority: .auxiliary)
        _ = queue.append(Data([0xFB, 1, 2, 0x01, 0x62]), priority: .auxiliary)

        XCTAssertEqual(queue.contents.map(\.data), [
            Data([0xFB, 0, 2, 0x01, 0x62]),
            Data([0xFB, 1, 2, 0x01, 0x62]),
        ])
    }

    func testToolHistoryClearDropsQueuedEntries() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xF5, 0, 0x83, 0x61, 0x62, 0x63]), priority: .auxiliary)
        _ = queue.append(Data([0xF5, 1, 0x81, 0x64]), priority: .auxiliary)
        _ = queue.append(Data([0xF5, 0, 0]), priority: .normal)
        _ = queue.append(Data([0xF5, 0, 0x81, 0x65]), priority: .auxiliary)

        XCTAssertEqual(queue.popNext()?.data, Data([0xF5, 0, 0]))
        XCTAssertEqual(queue.popNext()?.data, Data([0xF5, 0, 0x81, 0x65]))
        XCTAssertNil(queue.popNext())
    }

    func testEventsAndFingerprintFramesNeverCoalesce() {
        var queue = BuddyWriteQueue(capacity: 8)

        _ = queue.append(Data([0xF7, 1]), priority: .control)
        _ = queue.append(Data([0xF7, 1]), priority: .control)
        _ = queue.append(Data([0xD0, 0x22, 2]), priority: .control)
        _ = queue.append(Data([0xD0, 0x22, 2]), priority: .control)

        XCTAssertEqual(queue.count, 4)
    }
}
