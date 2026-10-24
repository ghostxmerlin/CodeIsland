import XCTest
@testable import CodeIslandCore

/// 美玲 key frames from the Tab5 (luna-work plan docs/superpowers/plans/2026-10-24-meiling.md, "Key Codec").
/// The vectors are a copy of luna-work tools/fixtures/meiling/keycodec_vectors.json (written by the Python reference).
final class MeilingFrameAssemblerTests: XCTestCase {
    struct Vector: Decodable {
        let name: String
        let kind: String
        let seq: Int
        let text: String
        let head: [UInt8]?
        let tail: [UInt8]?
    }

    private func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "meiling_keycodec_vectors", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url)).filter { $0.head != nil }
    }

    /// Feeds key-downs 2 ms apart, with `ackPause` ms between head and tail (the Mac's ack round trip).
    private func feed(_ usages: [UInt8], into assembler: MeilingFrameAssembler, at start: UInt64,
                      swallowed: inout [Bool]) -> (events: [MeilingAssemblerEvent], end: UInt64) {
        var events: [MeilingAssemblerEvent] = []
        var t = start
        for usage in usages {
            let keyCode = try! XCTUnwrap(MeilingKeyCodec.macKeyCode(forUsage: usage))
            let result = assembler.keyDown(keyCode, atMs: t)
            swallowed.append(result.swallow)
            events += result.events
            t += 2
        }
        return (events, t)
    }

    func testEveryVectorDecodes() throws {
        for v in try vectors() {
            let assembler = MeilingFrameAssembler()
            var swallowed: [Bool] = []
            let opened = feed(v.head!, into: assembler, at: 1000, swallowed: &swallowed)
            let kind: MeilingFrameKind = v.kind == "caption" ? .caption : .dictation
            XCTAssertEqual(opened.events, [.opened(kind)], v.name)
            let closed = feed(v.tail!, into: assembler, at: opened.end + 400, swallowed: &swallowed)
            XCTAssertEqual(closed.events, [.completed(kind, seq: UInt16(v.seq), text: v.text)], v.name)
            XCTAssertTrue(swallowed.allSatisfy { $0 }, "\(v.name): every frame key is swallowed")
        }
    }

    func testSimEncodingMatchesVectors() throws {
        for v in try vectors() {
            let kind: MeilingFrameKind = v.kind == "caption" ? .caption : .dictation
            let frame = try XCTUnwrap(MeilingKeyCodec.encodeFrame(kind: kind, seq: UInt16(v.seq), text: v.text))
            XCTAssertEqual(frame.head, v.head!.map { MeilingKeyCodec.macKeyCode(forUsage: $0)! }, v.name)
            XCTAssertEqual(frame.tail, v.tail!.map { MeilingKeyCodec.macKeyCode(forUsage: $0)! }, v.name)
        }
    }

    func testLoneMarkerPassesThrough() {
        let assembler = MeilingFrameAssembler()
        let f13 = MeilingKeyCodec.f13
        XCTAssertTrue(assembler.keyDown(f13, atMs: 0).swallow)  // held until the open window decides
        let a = assembler.keyDown(0 /* a */, atMs: 160)
        XCTAssertEqual(a.events, [.passThrough([f13])])
        XCTAssertFalse(a.swallow)
    }

    func testLoneMarkerReleasedByTick() {
        let assembler = MeilingFrameAssembler()
        _ = assembler.keyDown(MeilingKeyCodec.f14, atMs: 0)
        XCTAssertEqual(assembler.tick(atMs: 100), [])
        XCTAssertEqual(assembler.tick(atMs: 151), [.passThrough([MeilingKeyCodec.f14])])
    }

    func testBrokenOpenSequencePassesThrough() {
        let assembler = MeilingFrameAssembler()
        _ = assembler.keyDown(MeilingKeyCodec.f13, atMs: 0)
        _ = assembler.keyDown(MeilingKeyCodec.f15, atMs: 2)
        let a = assembler.keyDown(0, atMs: 4)
        XCTAssertEqual(a.events, [.passThrough([MeilingKeyCodec.f13, MeilingKeyCodec.f15])])
        XCTAssertFalse(a.swallow)
    }

    func testGapAbortsAndRestores() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "cjk" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let partial = feed(Array(v.tail!.prefix(2)), into: assembler, at: opened.end + 100, swallowed: &swallowed)
        XCTAssertEqual(assembler.tick(atMs: partial.end + 200), [])
        XCTAssertEqual(assembler.tick(atMs: partial.end + 301), [.failed(.dictation, reason: "gap")])
        // Transparent again once the drain's 300 ms of quiet are over: an ordinary key passes.
        XCTAssertFalse(assembler.keyDown(0, atMs: partial.end + 301 + 301).swallow)
    }

    func testAckWaitAllowsLongerFirstGap() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "ascii" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        XCTAssertEqual(assembler.tick(atMs: opened.end + 900), [])  // waiting for the IME switch + ack
        XCTAssertEqual(assembler.tick(atMs: opened.end + 1001), [.failed(.dictation, reason: "gap")])
    }

    func testNoAckCloseFails() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "cjk" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let closed = feed([0x6A, 0x6A], into: assembler, at: opened.end + 500, swallowed: &swallowed)
        XCTAssertEqual(closed.events, [.failed(.dictation, reason: "short")])
        XCTAssertTrue(swallowed.allSatisfy { $0 })
    }

    func testCrcMismatchFails() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "ascii" })
        var tail = v.tail!
        tail[3] = tail[3] == 0x04 ? 0x05 : 0x04  // change one payload symbol (0..2 are version + seq)
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let closed = feed(tail, into: assembler, at: opened.end + 50, swallowed: &swallowed)
        XCTAssertEqual(closed.events.last, .failed(.dictation, reason: "crc"))
    }

    func testStrayThenTailIsSwallowed() throws {
        // Review C2: after an abort the Tab5 keeps sending; the rest of the frame must not reach the app.
        let v = try XCTUnwrap(try vectors().first { $0.name == "mixed" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let firstHalf = Array(v.tail!.prefix(6))
        let half = feed(firstHalf, into: assembler, at: opened.end + 50, swallowed: &swallowed)
        let stray = assembler.keyDown(36, atMs: half.end)  // Return: the user's own key
        XCTAssertEqual(stray.events, [.failed(.dictation, reason: "stray")])
        XCTAssertFalse(stray.swallow)
        var rest: [Bool] = []
        let tail = feed(Array(v.tail!.dropFirst(6)), into: assembler, at: half.end + 2, swallowed: &rest)
        XCTAssertTrue(rest.allSatisfy { $0 }, "the remaining payload, CRC and F15 F15 are swallowed")
        XCTAssertEqual(tail.events, [])
        XCTAssertFalse(assembler.keyDown(0, atMs: tail.end + 10).swallow, "transparent again after F15 F15")
    }

    func testGapThenLateTailIsSwallowedUntilQuiet() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "ascii" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let part = feed(Array(v.tail!.prefix(5)), into: assembler, at: opened.end + 50, swallowed: &swallowed)
        XCTAssertEqual(assembler.tick(atMs: part.end + 301), [.failed(.dictation, reason: "gap")])
        var late: [Bool] = []
        _ = feed(Array(v.tail!.dropFirst(5).prefix(4)), into: assembler, at: part.end + 350, swallowed: &late)
        XCTAssertTrue(late.allSatisfy { $0 }, "late payload keys after a gap are drained")
        XCTAssertEqual(assembler.tick(atMs: part.end + 350 + 8 + 301), [])
        XCTAssertFalse(assembler.keyDown(0, atMs: part.end + 1000).swallow, "300 ms of quiet ends the drain")
    }

    func testStrayKeyFails() throws {
        let v = try XCTUnwrap(try vectors().first { $0.name == "ascii" })
        let assembler = MeilingFrameAssembler()
        var swallowed: [Bool] = []
        let opened = feed(v.head!, into: assembler, at: 0, swallowed: &swallowed)
        let returnKey: UInt16 = 36
        let stray = assembler.keyDown(returnKey, atMs: opened.end + 50)
        XCTAssertEqual(stray.events, [.failed(.dictation, reason: "stray")])
        XCTAssertFalse(stray.swallow)  // the user's own key reaches the app
    }
}
