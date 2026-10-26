import AVFoundation
import CoreAudio
import Foundation

/// Core Audio device lookup.
public enum MeilingAudioDevices {
    public struct Device: Sendable {
        public let id: AudioDeviceID
        public let uid: String, name: String
        public let inputs: Int, outputs: Int
    }

    public static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                   inputs: channels(id, kAudioObjectPropertyScopeInput),
                   outputs: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    /// First device whose name contains `name` (case-insensitive) and has the wanted direction.
    public static func find(_ name: String, output: Bool) -> Device? {
        all().first { $0.name.localizedCaseInsensitiveContains(name) && (output ? $0.outputs : $0.inputs) > 0 }
    }

    public static func defaultDevice(output: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    public static func device(_ id: AudioDeviceID) -> Device? { all().first { $0.id == id } }

    /// By UID, hidden devices included (the device list leaves those out).
    public static func find(uid: String) -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName),
                      inputs: channels(id, kAudioObjectPropertyScopeInput),
                      outputs: channels(id, kAudioObjectPropertyScopeOutput))
    }

    public static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }

    /// Virtual and aggregate inputs (Meyrin Virtual Mic, BlackHole, meeting-app loopbacks) carry no voice.
    public static func isVirtual(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeUnknown
    }

    /// The microphone to record the owner's voice from: the default input unless it is virtual (installing Meyrin
    /// Virtual Mic can make it the default), then the built-in mic, then any other real input.
    public static func voiceInput() -> AudioDeviceID? {
        if let id = defaultDevice(output: false), !isVirtual(id) { return id }
        let real = all().filter { $0.inputs > 0 && !isVirtual($0.id) }
        return (real.first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn } ?? real.first)?.id
    }

    /// Built-in speakers as the default output: in a meeting the mic would hear the other side.
    public static func defaultOutputIsBuiltInSpeaker() -> Bool {
        guard let id = defaultDevice(output: true) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeOutput
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return true }
        return source == 0x6973_706B  // 'ispk' internal speaker; 'hdpn' = headphones on the jack
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Streaming converter from any PCM format to mono Float32 at `rate` (keeps filter state across buffers).
final class MeilingResampler {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(rate: Double) {
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.downmix = buffer.format.channelCount > 1  // every input channel into the one output
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(max(-1, min(1, $0)) * 32767) }
    }
}

/// The microphone (default input or a named device) as 16 kHz PCM16 for Gemini and 48 kHz Float32 for the
/// passthrough. Starting it turns on the orange mic indicator; it needs the Microphone permission.
public final class MeilingMicCapture: @unchecked Sendable {
    public var on16k: (([Int16]) -> Void)?
    public var on48k: (([Float]) -> Void)?
    /// The device changed under the engine (a Bluetooth headset switching profile, a device unplugged) and the
    /// capture was restarted, or could not be: the reason, for the log.
    public var onRestart: ((String) -> Void)?
    /// The input level of each buffer (~20 per second), 0…1 on a -60…-15 dBFS scale, the loudest channel: a
    /// two-channel receiver (RØDE Wireless GO II) may carry the voice on channel 2 only. The HUD's level meter.
    public var onLevel: ((Float) -> Void)?
    public private(set) var running = false
    public private(set) var deviceName = ""
    /// The format the tap reads the device in (Hz), for the log.
    public private(set) var inputRate = 0.0
    /// Frames delivered since start and the loudest 16 kHz sample (0–1): a denied permission gives none or zeros.
    public private(set) var frames = 0
    public private(set) var peak: Float = 0

    // A fresh engine on every start: a reused one keeps the input format of the device it first opened, so after a
    // switch (Bluetooth headset ↔ built-in mic, 16 ↔ 48 kHz) it read the new mic in the old format and Gemini got
    // garbled or empty audio (owner 2026-10-25: wrong text, then no text at all).
    private var engine = AVAudioEngine()
    private let to16k = MeilingResampler(rate: 16000), to48k = MeilingResampler(rate: 48000)
    private let lock = NSLock()
    private var wanted = ""
    private var observer: NSObjectProtocol?
    private var restarts = MeilingRestartLimit()

    public init() {}

    /// Frames so far and the loudest sample since `resetPeak`, read together.
    public func snapshot() -> (frames: Int, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, peak)
    }

    public func resetPeak() {
        lock.lock()
        peak = 0
        lock.unlock()
    }

    /// `deviceName` empty = the system default input, or a real mic when that default is a virtual device.
    public func start(deviceName wanted: String = "") throws {
        guard !running else { return }
        self.wanted = wanted
        restarts = MeilingRestartLimit()
        lock.lock()  // before the tap goes live (review C7)
        frames = 0
        peak = 0
        lock.unlock()
        try startEngine()
        running = true
    }

    private func restart() {
        // Selecting the device on a fresh engine posts a configuration change too: only an engine the system really
        // stopped is restarted, and at most a few times (2026-10-25: an unguarded restart looped 88 times in 11 s).
        guard running, !engine.isRunning, restarts.allow() else { return }
        teardown()
        do {
            try startEngine()
            onRestart?("microphone restarted after a device change: \(deviceName)")
        } catch {
            onRestart?("microphone stopped after a device change: \(error)")
        }
    }

    private func startEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let chosen = wanted.isEmpty ? MeilingAudioDevices.voiceInput() : MeilingAudioDevices.find(wanted, output: false)?.id
        let systemInput = MeilingAudioDevices.defaultDevice(output: false)
        // The engine runs on a private aggregate of the default input and output (CADefaultDeviceAggregate on
        // macOS 26). Pointing it at an input-only device stops all IO without an error (2026-10-25: every press
        // heard nothing), so the device is selected only when it is not the system input.
        if var id = chosen, id != systemInput, let unit = input.audioUnit {
            if let device = MeilingAudioDevices.device(id), device.outputs == 0 {
                let current = systemInput.flatMap(MeilingAudioDevices.device)?.name ?? "a virtual device"
                throw MeilingAudioError("The system input is \(current): choose your real microphone (\(device.name)) in System Settings → Sound → Input")
            }
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MeilingAudioError("Microphone unavailable (no input device or no microphone access)") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let pcm = MeilingResampler.int16(self.to16k.convert(buffer))
            self.frames += pcm.count
            self.peak = max(self.peak, Float(pcm.map { abs(Int32($0)) }.max() ?? 0) / 32768)
            let hi = self.on48k == nil ? [] : self.to48k.convert(buffer)
            self.lock.unlock()
            if !pcm.isEmpty { self.on16k?(pcm) }
            if !hi.isEmpty { self.on48k?(hi) }
            if let onLevel = self.onLevel, let data = buffer.floatChannelData, buffer.frameLength > 0 {
                let count = Int(buffer.frameLength)
                let rms = (0..<Int(buffer.format.channelCount)).map { channel -> Float in
                    let samples = UnsafeBufferPointer(start: data[channel], count: count)
                    return (samples.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
                }.max() ?? 0
                let db = 20 * log10(max(rms, 1e-6))
                onLevel(min(1, max(0, (db + 60) / 45)))
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw MeilingAudioError("Microphone failed to start: \(error.localizedDescription)")
        }
        deviceName = MeilingAudioDevices.device(chosen ?? systemInput ?? 0)?.name ?? "default input"
        inputRate = format.sampleRate
        // AVAudioEngine stops by itself when its device's configuration changes, and says nothing else.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in self?.restart() }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    public func stop() {
        guard running else { return }
        teardown()
        running = false
    }
}

/// At most 3 restarts in 10 s: a device that keeps changing must not keep the engine restarting.
struct MeilingRestartLimit {
    private var times: [Date] = []

    mutating func allow(now: Date = Date()) -> Bool {
        times = times.filter { now.timeIntervalSince($0) < 10 }
        guard times.count < 3 else { return false }
        times.append(now)
        return true
    }
}

public struct MeilingAudioError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// The virtual microphone: plays 48 kHz mono into an output device; the meeting app picks the matching microphone.
/// Default: the hidden feed device of Meyrin Virtual Mic (drivers/MeyrinMic, UID MeyrinMicFeed_UID) → the app picks
/// "Meyrin Virtual Mic"; without that driver, BlackHole 2ch → the app picks "BlackHole 2ch". A jitter buffer starts playback at 120 ms and caps the queue at 1.5 s
/// (oldest dropped) so latency never grows (anti-goal: an unbounded output queue).
public final class MeilingVirtualMic: @unchecked Sendable {
    public static let defaultDeviceName = "MeyrinMicFeed_UID", fallbackDeviceName = "BlackHole"
    public static let visibleMicUID = "MeyrinMic_UID"
    /// What the meeting app should pick as its microphone, for the device opened by `start`.
    public private(set) var micNameForApps = ""
    static let rate = 48000.0, startFrames = 48 * 120, maxFrames = 48 * 1500

    public private(set) var running = false
    public private(set) var deviceName = ""
    /// What the device actually pulled: voiced frames (|x| > 0.01) and the peak, for bench checks.
    public private(set) var voicedFrames = 0
    public private(set) var renderedPeak: Float = 0
    /// The output device changed under the engine and playback was restarted, or could not be.
    public var onRestart: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var device: AudioDeviceID = 0
    private var observer: NSObjectProtocol?
    private var restarts = MeilingRestartLimit()
    private var ring: [Float] = []
    private var readIndex = 0
    private var primed = false
    private let lock = NSLock()

    public init() {}

    public func start(deviceName wanted: String = defaultDeviceName) throws {
        guard !running else { return }
        let device = MeilingAudioDevices.find(uid: wanted).flatMap { $0.outputs > 0 ? $0 : nil }
            ?? MeilingAudioDevices.find(wanted, output: true)
            ?? (wanted == Self.defaultDeviceName ? MeilingAudioDevices.find(Self.fallbackDeviceName, output: true) : nil)
        guard let device else {
            throw MeilingAudioError("Virtual mic \"\(wanted)\" not found: install Meyrin Virtual Mic (drivers/MeyrinMic) or BlackHole 2ch")
        }
        // The name the meeting app lists: the visible input of the same driver (an older install may still carry
        // its earlier name), or the device itself for BlackHole.
        micNameForApps = device.uid == Self.defaultDeviceName
            ? MeilingAudioDevices.find(uid: Self.visibleMicUID)?.name ?? "Meyrin Virtual Mic" : device.name
        self.device = device.id
        deviceName = device.name
        restarts = MeilingRestartLimit()
        try startEngine()
        running = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in self?.restart() }
    }

    private func restart() {
        guard running, !engine.isRunning, restarts.allow() else { return }  // see MeilingMicCapture.restart
        engine.stop()
        do {
            try startEngine()
            onRestart?("\(deviceName) restarted after a device change")
        } catch {
            onRestart?("\(deviceName) stopped after a device change: \(error)")
        }
    }

    private func startEngine() throws {
        guard let unit = engine.outputNode.audioUnit else { throw MeilingAudioError("Output unit unavailable") }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MeilingAudioError("Could not select \"\(deviceName)\" (\(status))") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        if source == nil { attachSource(format) }  // once: two nodes would drain the same ring
        engine.prepare()
        do { try engine.start() } catch {
            throw MeilingAudioError("Virtual mic failed to start: \(error.localizedDescription)")
        }
    }

    private func attachSource(_ format: AVAudioFormat) {
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let self, let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.read(into: out, count: Int(frameCount))
            for extra in buffers.dropFirst() {  // should not happen for a mono node; keep any extra channel equal
                extra.mData?.copyMemory(from: out, byteCount: Int(frameCount) * MemoryLayout<Float>.size)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.source = source
    }

    public func stop() {
        guard running else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        running = false
        clear()
    }

    public func write48k(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(contentsOf: samples)
        let queued = ring.count - readIndex
        if queued > Self.maxFrames {
            readIndex += queued - Self.maxFrames
        }
        compact()
    }

    /// Gemini's 24 kHz PCM16, upsampled 2x (linear, as the Tab5 does).
    public func write24k(_ pcm: [Int16]) {
        var up = [Float](repeating: 0, count: pcm.count * 2)
        for i in 0..<pcm.count {
            let a = Float(pcm[i]) / 32768, b = i + 1 < pcm.count ? Float(pcm[i + 1]) / 32768 : a
            up[i * 2] = a
            up[i * 2 + 1] = (a + b) / 2
        }
        write48k(up)
    }

    public func clear() {
        lock.lock()
        ring.removeAll()
        readIndex = 0
        primed = false
        lock.unlock()
    }

    public var queuedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return (ring.count - readIndex) / 48
    }

    private func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let queued = ring.count - readIndex
        if !primed, queued >= Self.startFrames { primed = true }
        let n = primed ? min(count, queued) : 0
        for i in 0..<n {
            let x = ring[readIndex + i]
            out[i] = x
            if abs(x) > 0.01 { voicedFrames += 1 }
            renderedPeak = max(renderedPeak, abs(x))
        }
        for i in n..<count { out[i] = 0 }
        readIndex += n
        if primed, n < count { primed = false }  // ran dry: re-prime before playing again
        compact()
    }

    private func compact() {
        if readIndex > 48000 {
            ring.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
