import AVFoundation
import CoreAudio
import Foundation

/// What the meeting app plays (the other side), captured with a Core Audio process tap (macOS 14.2+): a global
/// stereo tap that excludes this process, so the translated voice we play into the virtual mic is never heard
/// back. The audio still reaches the user's headphones unchanged (muteBehavior unmuted).
/// Needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription); without it the tap delivers
/// silence, so `peak` lets the caller tell the user.
public final class MeilingSystemTap: @unchecked Sendable {
    public var on16k: (([Int16]) -> Void)?
    public private(set) var running = false
    /// The loudest sample (0–1) of the last second, for "is anything coming in" checks.
    public private(set) var peak: Float = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let resampler = MeilingResampler(rate: 16000)
    private let queue = DispatchQueue(label: "meiling.tap")
    private var format: AVAudioFormat?
    private var peakWindow: Float = 0, peakFrames = 0

    public init() {}

    public func start() throws {
        guard !running else { return }
        guard #available(macOS 14.2, *) else { throw MeilingAudioError("The system audio tap needs macOS 14.2 or later") }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = Self.processObject(pid: ownPID).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.name = "Meyrin Meeting (them)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeilingAudioError("Could not create the system audio tap (\(status))") }
        tapID = tap

        guard let outputID = MeilingAudioDevices.defaultDevice(output: true) else {
            stop()
            throw MeilingAudioError("No default output device")
        }
        let outputUID = MeilingAudioDevices.string(outputID, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meyrin Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            stop()
            throw MeilingAudioError("Could not create the aggregate device (\(status))")
        }
        aggregateID = agg

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw MeilingAudioError("Could not read the tap format (\(status))")
        }
        self.format = format

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr, let proc else {
            stop()
            throw MeilingAudioError("Could not create the IOProc (\(status))")
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            stop()
            throw MeilingAudioError("System audio recording failed to start (\(status)): allow AISM in Privacy & Security → Screen & System Audio Recording")
        }
        running = true
    }

    public func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        if let data = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { peakWindow = max(peakWindow, abs(data[c][i])) }
            }
        }
        peakFrames += Int(buffer.frameLength)
        if peakFrames >= Int(format.sampleRate) {
            peak = peakWindow
            peakWindow = 0
            peakFrames = 0
        }
        let pcm = MeilingResampler.int16(resampler.convert(buffer))
        if !pcm.isEmpty { on16k?(pcm) }
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
