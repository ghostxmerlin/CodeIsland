import XCTest
@testable import CodeIslandCore

/// 美玲 without the Tab5 (docs/meiling-soft-design.md): the wire, the talk key, text clean-up and caption lines.
/// The .jsonl fixtures are luna-work tools/fixtures/meiling recordings of real server messages (P0, 2026-10-24).
final class MeilingSoftCoreTests: XCTestCase {
    private func messages(_ name: String) throws -> [MeilingServerMessage] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { MeilingServerMessage.parse(Data($0.utf8)) }
    }

    // MARK: protocol

    func testTranscribeSetupMatchesTheFirmware() throws {
        let data = MeilingLiveProtocol.transcribeSetup(vocabulary: ["Codex", "sdkconfig"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        XCTAssertEqual((setup["generationConfig"] as? [String: Any])?["responseModalities"] as? [String], ["TEXT"])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertEqual(transcription["customVocabulary"] as? [String], ["Codex", "sdkconfig"])
    }

    func testTranslateSetupKeepsTranscriptionsAtSetupLevel() throws {
        let data = MeilingLiveProtocol.translateSetup(target: "en", resumeHandle: "h1")
        let setup = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["setup"] as? [String: Any])
        XCTAssertNotNil(setup["inputAudioTranscription"])
        XCTAssertNotNil(setup["outputAudioTranscription"])
        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertNil(generation["inputAudioTranscription"])  // here the server closes with 1007
        let translation = try XCTUnwrap(generation["translationConfig"] as? [String: Any])
        XCTAssertEqual(translation["targetLanguageCode"] as? String, "en")
        XCTAssertEqual(translation["echoTargetLanguage"] as? Bool, false)
        XCTAssertEqual((setup["sessionResumption"] as? [String: Any])?["handle"] as? String, "h1")
    }

    func testAudioMessageIsLittleEndianBase64() throws {
        let data = MeilingLiveProtocol.audioMessage([1, -2])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let audio = try XCTUnwrap((root["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: audio["data"] as! String), Data([0x01, 0x00, 0xFE, 0xFF]))
    }

    func testRecordedDictationGivesOneFinalSentence() throws {
        let all = try messages("meiling_transcribe_zh")
        XCTAssertTrue(all.first?.setupComplete ?? false)
        let finals = all.filter(\.finalInputPresent).map(\.finalInput)
        XCTAssertEqual(finals, ["我们先把 USB-C 切成复合设备，然后加一个 CDC 端口。Codex 那边先别动 config，把改动列给我看。"])
        XCTAssertTrue(all.contains { $0.interimInput == "我 们 先 把" })
    }

    func testRecordedTranslationAssemblesIntoSentences() throws {
        var assembler = MeilingCaptionAssembler()
        var lines: [MeilingCaptionAssembler.Line] = []
        var audio = 0
        for (i, m) in try messages("meiling_translate_en_to_zh").enumerated() {
            audio += m.audio24k.count
            if let line = assembler.add(input: m.finalInput, output: m.outputText, atMs: UInt64(i)) { lines.append(line) }
        }
        if let rest = assembler.flush() { lines.append(rest) }
        XCTAssertGreaterThan(audio, 0)
        XCTAssertEqual(lines.first?.text, "我们下周能寄样品吗？")
        XCTAssertTrue(lines.map(\.text).joined().contains("我们需要先确认地址。"))
    }

    func testErrorAndResumption() {
        let error = MeilingServerMessage.parse(Data(#"{"error":{"message":"API key not valid"}}"#.utf8))
        XCTAssertEqual(error?.error, "API key not valid")
        let update = MeilingServerMessage.parse(Data(#"{"sessionResumptionUpdate":{"newHandle":"abc","resumable":true}}"#.utf8))
        XCTAssertEqual(update?.resumptionHandle, "abc")
        XCTAssertEqual(update?.resumable, true)
        XCTAssertNil(MeilingServerMessage.parse(Data("not json".utf8)))
    }

    // MARK: talk key

    func testTapLatchesAndTheNextTapStops() {
        var g = MeilingTalkGesture()
        XCTAssertEqual(g.down(atMs: 0), .start)
        XCTAssertEqual(g.up(atMs: 120), .none)
        XCTAssertTrue(g.talking)
        XCTAssertEqual(g.down(atMs: 5000), .none)
        XCTAssertEqual(g.up(atMs: 5080), .stop)
        XCTAssertFalse(g.talking)
    }

    func testHoldIsPushToTalk() {
        var g = MeilingTalkGesture()
        XCTAssertEqual(g.down(atMs: 0), .start)
        XCTAssertEqual(g.up(atMs: 300), .stop)
    }

    func testHoldOnlyStopsOnEveryRelease() {
        var g = MeilingTalkGesture()
        g.holdOnly = true
        XCTAssertEqual(g.down(atMs: 0), .start)
        XCTAssertEqual(g.up(atMs: 120), .stop)  // a tap no longer latches
        XCTAssertFalse(g.talking)
        XCTAssertEqual(g.down(atMs: 1000), .start)
        XCTAssertEqual(g.up(atMs: 4000), .stop)
    }

    func testShortcutCancelsAndTypesNothing() {
        var g = MeilingTalkGesture()
        XCTAssertEqual(g.down(atMs: 0), .start)
        XCTAssertEqual(g.chord(), .cancel)  // ⌘C
        XCTAssertEqual(g.chord(), .none)
        XCTAssertEqual(g.up(atMs: 150), .none)
        XCTAssertFalse(g.talking)
        XCTAssertEqual(g.down(atMs: 1000), .start)  // the next press works normally
    }

    func testShortcutWhileLatchedKeepsTalking() {
        var g = MeilingTalkGesture()
        _ = g.down(atMs: 0)
        _ = g.up(atMs: 100)
        XCTAssertEqual(g.down(atMs: 2000), .none)
        XCTAssertEqual(g.chord(), .none)
        XCTAssertEqual(g.up(atMs: 2100), .none)
        XCTAssertTrue(g.talking)
    }

    // MARK: corrections

    private func pairs(_ heard: String, _ right: String) -> [String] {
        MeilingCorrections.pairs(heard: heard, corrected: right).map { "\($0.heard)→\($0.right)" }
    }

    func testCorrectionPairsWidenOneCjkCharacterAndWholeLatinWords() {
        XCTAssertEqual(pairs("然后看美林的同传", "然后看美玲的同传"), ["美林→美玲"])  // never 林 → 玲 alone
        XCTAssertEqual(pairs("用 SIDF 的 app flash 烧录", "用 ESP-IDF 的 app-flash 烧录"), ["SIDF→ESP-IDF", "app flash→app-flash"])
        XCTAssertEqual(pairs("后来，Luna 来了。", "后来可以有声音了。"), [])  // a rewrite, not a misheard word
        XCTAssertEqual(pairs("一样的", "一样的"), [])
        XCTAssertEqual(pairs("把螺丝拧到地板上", "把螺丝拧到底板上"), ["地板→底板"])
    }

    func testCorrectionsApplyLongestFirstAndKeepTheRightWord() {
        let list = [MeilingCorrection(heard: "美林", right: "美玲"), MeilingCorrection(heard: "Mac", right: "MacBook"),
                    MeilingCorrection(heard: "听筒", right: "听写", enabled: false)]
        XCTAssertEqual(MeilingCorrections.apply(list, to: "美林的 Mac 和 MacBook，听筒"), "美玲的 MacBook 和 MacBook，听筒")
    }

    func testLearningCountsAndTheVocabularyPutsCorrectionsFirst() {
        var list: [MeilingCorrection] = []
        MeilingCorrections.learn([("美林", "美玲")], into: &list, now: Date(timeIntervalSince1970: 1))
        MeilingCorrections.learn([("美林", "美玲"), ("地板", "底板")], into: &list, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(list.map(\.count), [2, 1])
        let vocab = MeilingCorrections.vocabulary(list, terms: ["Tab5", "美玲", "aism"], limit: 3)
        XCTAssertEqual(vocab, ["美玲", "底板", "Tab5"])  // both learned (newest first, no repeat), then the list, capped
    }

    // MARK: history

    private func historyFile(max: Int = 1000) -> MeilingHistoryFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return MeilingHistoryFile(url: dir.appendingPathComponent("dictation-history.jsonl"), maxEntries: max)
    }

    func testHistoryRoundTripsAndIsOwnerOnly() throws {
        let file = historyFile()
        var typed = MeilingHistoryEntry(text: "先别动 sdkconfig。", source: "Mac")
        typed.status = .typed
        let lost = MeilingHistoryEntry(text: "第二句。", source: "Tab5", status: .notTyped, note: "no text field")
        try file.save([typed, lost])
        let loaded = file.load()
        XCTAssertEqual(loaded.map(\.text), ["先别动 sdkconfig。", "第二句。"])
        XCTAssertEqual(loaded.map(\.status), [.typed, .notTyped])
        XCTAssertEqual(loaded[1].note, "no text field")
        XCTAssertEqual(abs(loaded[0].date.timeIntervalSince(typed.date)) < 1, true)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testHistoryKeepsWhatWasHeardBesideWhatWasTyped() {
        var e = MeilingHistoryEntry(text: "然后看美林的同传", typed: "然后看美玲的同传", source: "Mac")
        XCTAssertEqual(e.text, "然后看美林的同传")  // corrections are learned against the recognizer's own words
        XCTAssertEqual(e.shown, "然后看美玲的同传")
        e.corrected = "然后看美龄的同传"
        XCTAssertEqual(e.shown, "然后看美龄的同传")
        XCTAssertNil(MeilingHistoryEntry(text: "一样", typed: "一样", source: "Mac").typed)
    }

    func testHistorySkipsABadLineAndKeepsTheNewest() throws {
        let file = historyFile(max: 3)
        try file.save((1...5).map { MeilingHistoryEntry(text: "句子 \($0)", source: "Mac") })
        XCTAssertEqual(file.load().map(\.text), ["句子 3", "句子 4", "句子 5"])
        let handle = try FileHandle(forWritingTo: file.url)
        handle.seekToEndOfFile()
        handle.write(Data("{not json\n".utf8))
        try handle.close()
        XCTAssertEqual(file.load().count, 3)
        XCTAssertTrue(historyFile().load().isEmpty)  // no file yet
    }

    // MARK: text

    func testCompactCjkSpaces() {
        XCTAssertEqual(MeilingText.compactCjkSpaces("我 们 先 把 USB-C 切 成 复 合"), "我们先把 USB-C 切成复合")
        XCTAssertEqual(MeilingText.compactCjkSpaces("hello world"), "hello world")
        XCTAssertEqual(MeilingText.compactCjkSpaces("好 ， 的"), "好，的")
    }

    func testTraditionalToSimplified() {
        XCTAssertEqual(MeilingText.simplified("我們先把複合設備"), "我们先把复合设备")
    }

    func testQuietFlushesAnUnfinishedLine() {
        var a = MeilingCaptionAssembler()
        XCTAssertNil(a.add(input: "and then", output: "然后", atMs: 0))
        XCTAssertNil(a.tick(atMs: 1400))
        XCTAssertEqual(a.tick(atMs: 1600), .init(text: "然后", original: "and then"))
        XCTAssertNil(a.tick(atMs: 5000))
    }
}
