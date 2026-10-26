import AVFoundation
import CodeIslandCore
import Foundation
import MeilingSoftKit

// meiling-soft: benches 美玲's Mac-only engines without the app (luna-work spec 2026-10-24-meiling-design, Mac
// edition: docs/meiling-soft-design.md). The key comes from --env FILE (GEMINI_API_KEY=...) and is never printed.
//   meiling-soft devices
//   meiling-soft dictate --wav F.wav [--vocab terms.json]      stream a 16 kHz mono WAV in real time
//   meiling-soft dictate --mic SECONDS [--vocab terms.json]    talk into the default mic
//   meiling-soft out --wav F.wav [--vmic NAME|UID] [--monitor NAME|UID]           zh speech → English into the virtual mic (Meyrin Virtual Mic,
//                                                              else BlackHole; reports how much
//                                                              voiced audio the device pulled)
//   meiling-soft in --seconds N                                system audio → Chinese captions (play something)
//   meiling-soft in --wav F.wav                                the other side from a WAV instead of the tap
let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let start = Date()
func say(_ kind: String, _ detail: String = "") {
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print(String(format: "%6d ms  %-8@ %@", ms, kind as NSString, detail as NSString))
    fflush(stdout)
}

func apiKey() -> String {
    // The key file AISM uses (Settings → Meyrin → Gemini API Key), or --env FILE.
    let path = option("--env")
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/AISM/meiling.env")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    for line in text.split(separator: "\n") where line.hasPrefix("GEMINI_API_KEY=") {
        return String(line.dropFirst("GEMINI_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
    }
    fail("GEMINI_API_KEY missing in \(path)")
}

func vocabulary() -> [String] {
    guard let path = option("--vocab"), let data = FileManager.default.contents(atPath: path) else { return [] }
    if let terms = try? JSONDecoder().decode([[String: String]].self, from: data) { return terms.compactMap { $0["term"] } }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}

func wav16k(_ path: String) -> [Int16] {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16,
                                      interleaved: true),
          file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let data = buffer.int16ChannelData
    else { fail("\(path): need a 16 kHz mono WAV") }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
}

/// Feeds `pcm` in 100 ms steps at real-time pace on a background thread, then calls `done`.
func stream(_ pcm: [Int16], into feed: @escaping ([Int16]) -> Void, done: @escaping () -> Void) {
    Thread.detachNewThread {
        var offset = 0
        let t0 = Date()
        while offset < pcm.count {
            let chunk = Array(pcm[offset..<min(offset + 1600, pcm.count)])
            feed(chunk)
            offset += chunk.count
            let due = t0.addingTimeInterval(Double(offset) / 16000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        done()
    }
}

func run(for seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

guard args.count >= 2 else { fail("usage: meiling-soft devices|dictate|out|in ... (see the header of main.swift)") }
switch args[1] {
case "mic":  // the capture alone: frames and peak after N seconds
    let mic = MeilingMicCapture()
    var chunks = 0, levels: [Float] = []
    mic.on16k = { _ in chunks += 1 }
    mic.onLevel = { levels.append($0) }
    do { try mic.start(deviceName: option("--device") ?? "") } catch { fail("\(error)") }
    say("mic", "\(mic.deviceName) at \(mic.inputRate) Hz")
    run(for: Double(option("--seconds") ?? "2") ?? 2)
    say("mic", "frames=\(mic.snapshot().frames) peak=\(mic.snapshot().peak) chunks=\(chunks)")
    say("level", String(format: "%d readings, min %.2f max %.2f", levels.count, levels.min() ?? 0, levels.max() ?? 0))
    mic.stop()

case "devices":
    for d in MeilingAudioDevices.all() {
        print("\(d.id)\tin=\(d.inputs)\tout=\(d.outputs)\t\(d.name)\t\(d.uid)")
    }
    print("default in=\(MeilingAudioDevices.defaultDevice(output: false) ?? 0) out=\(MeilingAudioDevices.defaultDevice(output: true) ?? 0) builtInSpeaker=\(MeilingAudioDevices.defaultOutputIsBuiltInSpeaker())")
    print("voice mic=\(MeilingAudioDevices.voiceInput().flatMap(MeilingAudioDevices.device)?.name ?? "none")")

case "dictate":
    let engine = MeilingDictationEngine(apiKey: apiKey(), vocabulary: vocabulary())
    engine.onState = { say("state", "\($0)") }
    engine.onInterim = { say("interim", $0) }
    engine.onFinal = { text, _ in say("FINAL", text) }
    engine.onError = { say("error", $0) }
    engine.onTalkSummary = { say("mic", $0) }
    if let wav = option("--wav") {
        let pcm = wav16k(wav)
        engine.begin(useMic: false)
        say("audio", "\(pcm.count / 16) ms of audio")
        stream(pcm, into: { engine.feed($0) }) {
            DispatchQueue.main.async { say("release"); engine.end() }
        }
        run(for: Double(pcm.count) / 16000 + 4)
    } else {
        let seconds = Double(option("--mic") ?? "8") ?? 8
        engine.begin(micName: option("--device") ?? "")
        say("talk", "mic=\(engine.mic.deviceName) for \(seconds) s")
        run(for: seconds)
        say("release", String(format: "mic frames=%d peak=%.3f", engine.mic.frames, engine.mic.peak))
        engine.end()
        run(for: 3)
    }
    engine.shutdown()

case "out":
    guard let wav = option("--wav") else { fail("out needs --wav") }
    let pcm = wav16k(wav)
    let engine = MeilingMeetingEngine(apiKey: apiKey())
    engine.onStatus = { say("status", $0) }
    engine.onCaption = { say($0.mine ? "MINE" : "THEIRS", "\($0.text)  ‹\($0.original)›") }
    engine.onPending = { say("pending", $0.text) }
    do {
        try engine.start(useMic: false, systemAudio: false,
                         virtualMicName: option("--vmic") ?? MeilingVirtualMic.defaultDeviceName)
    } catch { fail("\(error)") }
    say("vmic", "\(engine.virtualMic.deviceName) → apps pick \(engine.virtualMic.micNameForApps)")
    if let device = option("--monitor") {
        engine.setMonitor(true, device: device)
        say("monitor", engine.monitoring ? engine.monitor.deviceName : "failed")
    }
    run(for: 1.5)
    engine.startTalk()
    say("talk", "\(pcm.count / 16) ms of audio")
    stream(pcm, into: { engine.feedOutgoing($0) }) {
        DispatchQueue.main.async { say("release"); engine.stopTalk() }
    }
    run(for: Double(pcm.count) / 16000 + 9)
    say("vmic", String(format: "%@ pulled %.1f s of voiced audio, peak %.3f", engine.virtualMic.deviceName,
                       Double(engine.virtualMic.voicedFrames) / 48000, engine.virtualMic.renderedPeak))
    if engine.monitoring {
        say("monitor", String(format: "%@ played %.1f s of voiced audio, peak %.3f", engine.monitor.deviceName,
                              Double(engine.monitor.voicedFrames) / 48000, engine.monitor.renderedPeak))
    }
    engine.stop()

case "in":
    let engine = MeilingMeetingEngine(apiKey: apiKey())
    engine.onStatus = { say("status", $0) }
    engine.onCaption = { say($0.mine ? "MINE" : "THEIRS", "\($0.text)  ‹\($0.original)›") }
    if let wav = option("--wav") {
        let pcm = wav16k(wav)
        do { try engine.start(useMic: false, systemAudio: false) } catch { fail("\(error)") }
        stream(pcm + [Int16](repeating: 0, count: 48000), into: { engine.feedIncoming($0) }) {}
        run(for: Double(pcm.count) / 16000 + 6)
    } else {
        let seconds = Double(option("--seconds") ?? "15") ?? 15
        do { try engine.start(useMic: false, systemAudio: true) } catch { fail("\(error)") }
        say("tap", "listening to system audio for \(seconds) s")
        let probe = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in say("peak", String(format: "%.3f", engine.tap.peak)) }
        run(for: seconds)
        probe.invalidate()
    }
    engine.stop()
    run(for: 0.2)

default:
    fail("unknown command \(args[1])")
}
