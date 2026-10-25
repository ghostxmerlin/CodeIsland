import CodeIslandCore
import Foundation

/// 美玲 dictation without the Tab5: Mac mic → gemini-3.5-transcribe-live. Only confirmed sentences
/// (inputTranscription) are handed to `onFinal`; interim text is for display only. Callbacks run on the session
/// queue. The session connects on the first press, stays up between presses and closes after 5 idle minutes.
/// Drive it from one thread (the app's main thread); only the mic callback runs elsewhere.
public final class MeilingDictationEngine: @unchecked Sendable {
    public static let idleClose: TimeInterval = 300, rotateAfter: TimeInterval = 570
    /// The mic keeps recording this long after the key is released: the last syllable is often still being said
    /// (owner 2026-10-25: words were cut off at release). A press within it continues the same utterance.
    public static let releaseTail: TimeInterval = 0.5

    public var onInterim: ((String) -> Void)?
    /// The sentence and the session that produced it: compare with `currentSession` (on the driving thread) to
    /// drop finals of a cancelled talk that were already in flight.
    public var onFinal: ((String, ObjectIdentifier) -> Void)?
    public var onState: ((MeilingLiveSession.State) -> Void)?
    public var onError: ((String) -> Void)?
    /// One line per press for the log: the mic, how much it heard and how loud (no text).
    public var onTalkSummary: ((String) -> Void)?

    public let mic = MeilingMicCapture()
    private var talkStarted = Date()
    private var pendingEnd: DispatchWorkItem?
    private let apiKey: String
    private let vocabulary: [String]
    private var session: MeilingLiveSession?
    private var idle: DispatchWorkItem?
    private var talkingTo: MeilingLiveSession?  // read by the mic thread, under `lock`
    private let lock = NSLock()
    public var currentSession: ObjectIdentifier? { session.map(ObjectIdentifier.init) }
    public private(set) var talking = false {
        didSet {
            lock.lock()
            talkingTo = talking ? session : nil
            lock.unlock()
        }
    }

    public init(apiKey: String, vocabulary: [String]) {
        self.apiKey = apiKey
        self.vocabulary = vocabulary
        mic.on16k = { [weak self] pcm in
            guard let self else { return }
            self.lock.lock()
            let target = self.talkingTo
            self.lock.unlock()
            target?.send(pcm)
        }
    }

    /// `useMic` false: the caller feeds PCM itself (`feed`), e.g. from a WAV file.
    public func begin(useMic: Bool = true, micName: String = "") {
        idle?.cancel()
        if let pending = pendingEnd {  // pressed again within the release tail: the same utterance goes on
            pending.cancel()
            pendingEnd = nil
            if talking { return }
        }
        if let s = session, let since = s.readySince, Date().timeIntervalSince(since) > Self.rotateAfter {
            s.close()  // transcribe-live caps a session at 10 minutes: rotate between presses
            session = nil
        }
        let s = session ?? makeSession()
        session = s
        s.open()
        talking = true
        talkStarted = Date()
        guard useMic else { return }
        mic.onRestart = { [weak self] why in self?.onTalkSummary?(why) }
        do { try mic.start(deviceName: micName) } catch {
            talking = false
            scheduleIdleClose()  // no press may follow: do not leave the session reconnecting forever
            onError?("\(error)")
        }
    }

    public func feed(_ pcm: [Int16]) {
        guard talking else { return }
        session?.send(pcm)
    }

    /// Release: recording goes on for `releaseTail`, then audioStreamEnd; the model finalizes the last sentence
    /// ~0.5 s after that.
    public func end() {
        guard talking, pendingEnd == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.finishEnd() }
        pendingEnd = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTail, execute: item)
    }

    private func finishEnd() {
        pendingEnd = nil
        guard talking else { return }
        talking = false
        if mic.running {
            let (frames, peak) = mic.snapshot()
            let seconds = Date().timeIntervalSince(talkStarted)
            onTalkSummary?(String(format: "talk %.1f s: mic %@ at %.0f Hz, %.1f s heard, peak %.3f",
                                  seconds, mic.deviceName, mic.inputRate, Double(frames) / 16000, peak))
            if seconds > 1.5, frames == 0 || peak < 0.002 {
                onError?(frames == 0 ? "No sound from the microphone (\(mic.deviceName))"
                                     : "The microphone (\(mic.deviceName)) only heard silence")
            }
        }
        mic.stop()
        session?.endAudio()
        scheduleIdleClose()
    }

    /// A chord or Esc: drop this utterance. Closing the socket is the only way to make sure no final arrives.
    public func cancel() {
        pendingEnd?.cancel()
        pendingEnd = nil
        talking = false
        mic.stop()
        session?.close()
        session = nil
    }

    public func shutdown() {
        idle?.cancel()
        cancel()
    }

    private func scheduleIdleClose() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.talking else { return }
            self.session?.close()
            self.session = nil
        }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleClose, execute: item)
    }

    private func makeSession() -> MeilingLiveSession {
        let s = MeilingLiveSession(label: "dictation", kind: .transcribe(vocabulary: vocabulary), apiKey: apiKey)
        s.reconnectWhenIdle = false
        s.onState = { [weak self] state in self?.onState?(state) }
        let id = ObjectIdentifier(s)
        s.onMessage = { [weak self] m in
            guard let self else { return }
            if !m.interimInput.isEmpty { self.onInterim?(MeilingText.compactCjkSpaces(m.interimInput)) }
            if m.finalInputPresent, !MeilingText.isBlank(m.finalInput) {
                self.onFinal?(MeilingText.compactCjkSpaces(m.finalInput).trimmingCharacters(in: .whitespaces), id)
            }
        }
        return s
    }
}

/// 美玲 meeting interpretation without the Tab5 (luna-work app/meiling/meeting.cpp, Mac edition):
///   outgoing  Mac mic (only while talking) → live-translate en → virtual mic (BlackHole) + shared caption window
///   incoming  system audio (the meeting app, via a process tap) → live-translate zh-Hans → private captions;
///             its translated audio is never played
/// Releasing talk streams 2 s of zeros before audioStreamEnd (the model translates the last clause only when
/// silence follows); translated audio keeps playing until the turn ends (at most 8 s). The virtual mic carries only
/// translation while talking or in that tail, the user's own voice with passthrough on, or silence. With the monitor
/// on, the same translated voice also plays on the default output (the owner's headphones, 耳返); the system tap
/// leaves this process out, so it is never translated back.
public final class MeilingMeetingEngine: @unchecked Sendable {
    public static let flushSeconds = 2.0, tailCap: TimeInterval = 8

    public struct Caption: Sendable {
        public let mine: Bool
        public let text: String, original: String
    }

    public var onCaption: ((Caption) -> Void)?
    public var onPending: ((Caption) -> Void)?   // the line still being assembled (for a live preview)
    public var onStatus: ((String) -> Void)?

    public let mic = MeilingMicCapture()
    public let virtualMic = MeilingVirtualMic()
    public let monitor = MeilingVirtualMic()  // the same player, on the default output
    public let tap = MeilingSystemTap()
    private let outgoing: MeilingLiveSession, incoming: MeilingLiveSession
    private let lock = NSLock()
    private var mine = MeilingCaptionAssembler(), theirs = MeilingCaptionAssembler()
    private var ticker: DispatchSourceTimer?
    public private(set) var active = false, talking = false, passthrough = false, monitoring = false
    private var tailUntil: Date?
    /// The mic still feeds the translation this long after release (the last syllable); the 2 s of silence that
    /// make the model translate the last clause start after it.
    public static let releaseTail: TimeInterval = 0.5
    private var micTailUntil: Date?
    private var releasedAt: Date?
    private var flushSent = 0
    private var ended = true
    // One utterance, for the log line after it and the no-sound warning (owner 2026-10-25: nothing happened, no error).
    private var talkStarted: Date?, talkFrames0 = 0, silenceWarned = false
    private var heardChars = 0, translatedSamples = 0
    public static let silenceWarnAfter: TimeInterval = 3

    public init(apiKey: String) {
        outgoing = MeilingLiveSession(label: "meeting.out", kind: .translate(target: "en"), apiKey: apiKey)
        incoming = MeilingLiveSession(label: "meeting.in", kind: .translate(target: "zh-Hans"), apiKey: apiKey)
        outgoing.onMessage = { [weak self] m in self?.outgoingMessage(m) }
        incoming.onMessage = { [weak self] m in self?.incomingMessage(m) }
        outgoing.onState = { [weak self] s in self?.report("Outgoing", s) }
        incoming.onState = { [weak self] s in self?.report("Incoming", s) }
        mic.on16k = { [weak self] pcm in
            guard let self else { return }
            self.lock.lock()
            let inTail = self.micTailUntil.map { Date() < $0 } ?? false
            let send = self.active && (self.talking || inTail) && !self.passthrough
            self.lock.unlock()
            if send { self.outgoing.send(pcm) }
        }
        mic.on48k = { [weak self] samples in
            guard let self else { return }
            self.lock.lock()
            let through = self.active && self.passthrough
            self.lock.unlock()
            if through { self.virtualMic.write48k(samples) }
        }
        tap.on16k = { [weak self] pcm in self?.incoming.send(pcm) }
        mic.onRestart = { [weak self] why in self?.onStatus?(why) }
        virtualMic.onRestart = { [weak self] why in self?.onStatus?("virtual mic: \(why)") }
        monitor.onRestart = { [weak self] why in self?.onStatus?("monitor: \(why)") }
    }

    /// `systemAudio` false: the caller feeds the other side itself (`feedIncoming`), e.g. from a WAV file.
    public func start(useMic: Bool = true, micName: String = "", systemAudio: Bool = true,
                      virtualMicName: String = MeilingVirtualMic.defaultDeviceName, monitor: Bool = false) throws {
        guard !active else { return }
        try virtualMic.start(deviceName: virtualMicName)  // first, so this process exists when the tap excludes it
        if monitor { setMonitor(true) }
        if systemAudio {
            do { try tap.start() } catch {
                virtualMic.stop()
                setMonitor(false)
                throw error
            }
        }
        if useMic {
            do { try mic.start(deviceName: micName) } catch {
                tap.stop()
                virtualMic.stop()
                setMonitor(false)
                throw error
            }
        }
        lock.lock()
        active = true
        talking = false
        passthrough = false
        ended = true
        tailUntil = nil
        lock.unlock()
        outgoing.open()
        incoming.open()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "meiling.meeting.tick"))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    public func stop() {
        lock.lock()
        active = false
        talking = false
        let a = mine.flush(), b = theirs.flush()
        lock.unlock()
        ticker?.cancel()
        ticker = nil
        mic.stop()
        tap.stop()
        virtualMic.stop()
        setMonitor(false)
        outgoing.close()
        incoming.close()
        if let a { onCaption?(Caption(mine: true, text: a.text, original: a.original)) }
        if let b { onCaption?(Caption(mine: false, text: b.text, original: b.original)) }
    }

    public func startTalk() {
        lock.lock()
        defer { lock.unlock() }
        guard active, !passthrough else { return }
        talking = true
        tailUntil = nil
        releasedAt = nil
        micTailUntil = nil
        ended = false
        flushSent = 0
        talkStarted = Date()
        talkFrames0 = mic.snapshot().frames
        silenceWarned = false
        heardChars = 0
        translatedSamples = 0
        mic.resetPeak()
        virtualMic.clear()
        monitor.clear()
    }

    public func stopTalk() {
        lock.lock()
        defer { lock.unlock() }
        guard talking else { return }
        talking = false
        micTailUntil = Date().addingTimeInterval(Self.releaseTail)
        releasedAt = micTailUntil
        tailUntil = Date().addingTimeInterval(Self.releaseTail + Self.tailCap)
        flushSent = 0
    }

    public func setPassthrough(_ on: Bool) {
        lock.lock()
        if on { talking = false }
        passthrough = on
        tailUntil = nil
        lock.unlock()
        virtualMic.clear()
        monitor.clear()
    }

    /// 耳返: the translated voice also on the default output (or `device`, a name or UID: CLI benches). A failure
    /// only reports: the meeting goes on.
    public func setMonitor(_ on: Bool, device: String? = nil) {
        if on {
            guard !monitor.running else { return }
            guard let uid = device ?? MeilingAudioDevices.defaultDevice(output: true).flatMap(MeilingAudioDevices.device)?.uid
            else { return }
            do { try monitor.start(deviceName: uid) } catch {
                onStatus?("Monitor: \(error)")
                return
            }
        } else {
            monitor.stop()
        }
        lock.lock()
        monitoring = on
        lock.unlock()
    }

    /// The other side from somewhere other than the system tap (CLI tests).
    public func feedIncoming(_ pcm: [Int16]) { incoming.send(pcm) }

    /// The user's voice from somewhere other than the mic (CLI tests); obeys talk like the mic does.
    public func feedOutgoing(_ pcm: [Int16]) {
        lock.lock()
        let send = active && talking && !passthrough
        lock.unlock()
        if send { outgoing.send(pcm) }
    }

    private func tick() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        var zeros = 0, end = false
        if let releasedAt, !ended, Date() >= releasedAt {  // after the release tail
            let due = Int(min(Date().timeIntervalSince(releasedAt), Self.flushSeconds) * 16000)
            zeros = max(0, due - flushSent)
            flushSent = due
            if Date().timeIntervalSince(releasedAt) >= Self.flushSeconds {
                ended = true
                end = true
            }
        }
        if let until = tailUntil, Date() > until { tailUntil = nil }
        let now = Self.nowMs()
        let a = mine.tick(atMs: now), b = theirs.tick(atMs: now)
        var warning: String?, summary: String?
        if talking, mic.running, !silenceWarned, let talkStarted, Date().timeIntervalSince(talkStarted) > Self.silenceWarnAfter {
            let (frames, peak) = mic.snapshot()
            if frames == talkFrames0 || peak < 0.002 {
                silenceWarned = true
                warning = frames == talkFrames0 ? "no sound from the microphone (\(mic.deviceName)): it delivers nothing"
                    : "the microphone (\(mic.deviceName)) only hears silence"
            }
        }
        if end, let talkStarted {
            let (frames, peak) = mic.snapshot()
            summary = String(format: "talk %.1f s: mic %@ %.1f s peak %.3f, heard %d chars, translated %.1f s",
                             Date().timeIntervalSince(talkStarted) - Self.flushSeconds - Self.releaseTail, mic.deviceName,
                             Double(frames - talkFrames0) / 16000, peak, heardChars, Double(translatedSamples) / 24000)
        }
        lock.unlock()
        if let warning { onStatus?("WARN: " + warning) }
        if let summary { onStatus?(summary) }
        if zeros > 0 { outgoing.send([Int16](repeating: 0, count: zeros)) }
        if end { outgoing.endAudio() }
        if let a { onCaption?(Caption(mine: true, text: a.text, original: a.original)) }
        if let b { onCaption?(Caption(mine: false, text: b.text, original: b.original)) }
    }

    private func outgoingMessage(_ m: MeilingServerMessage) {
        lock.lock()
        guard active else {  // stopped: the closing sessions may still deliver a message or two
            lock.unlock()
            return
        }
        if m.turnComplete, !talking { tailUntil = nil }
        heardChars += m.finalInput.count
        translatedSamples += m.audio24k.count
        let play = !m.audio24k.isEmpty && (talking || tailUntil != nil) && !passthrough
        let hear = play && monitoring
        let line = mine.add(input: MeilingText.simplified(m.finalInput), output: m.outputText, atMs: Self.nowMs())
        let preview = mine.pending
        lock.unlock()
        if play { virtualMic.write24k(m.audio24k) }
        if hear { monitor.write24k(m.audio24k) }
        if let line { onCaption?(Caption(mine: true, text: line.text, original: line.original)) }
        else if let preview, !m.outputText.isEmpty || !m.finalInput.isEmpty {
            onPending?(Caption(mine: true, text: preview.text, original: preview.original))
        }
    }

    private func incomingMessage(_ m: MeilingServerMessage) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        let line = theirs.add(input: m.finalInput, output: m.outputText, atMs: Self.nowMs())
        let preview = theirs.pending
        lock.unlock()
        if let line { onCaption?(Caption(mine: false, text: line.text, original: line.original)) }
        else if let preview, !m.outputText.isEmpty || !m.finalInput.isEmpty {
            onPending?(Caption(mine: false, text: preview.text, original: preview.original))
        }
    }

    private func report(_ side: String, _ state: MeilingLiveSession.State) {
        switch state {
        case .ready: onStatus?("\(side): connected")
        case .connecting: onStatus?("\(side): connecting")
        case let .failed(why): onStatus?("\(side): \(why), retrying")
        case let .gaveUp(why): onStatus?("\(side): \(why), stopped")
        case .closed: break
        }
    }

    static func nowMs() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
}
