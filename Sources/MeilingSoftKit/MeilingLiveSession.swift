import CodeIslandCore
import Foundation

/// One Gemini Live WebSocket session (dictation or one meeting direction). All state lives on `queue`; callbacks
/// run there too. Audio sent before setupComplete is held (at most 10 s, oldest dropped) so a press never loses
/// its first words while the socket connects.
///
/// Policy (luna-work app/meiling/session_policy.*): setupComplete within 10 s; failures back off 1 / 4 / 16 s;
/// persistent ones (bad key, quota, 4xx close codes) give up after the third; goAway reconnects at once with the
/// resumption handle (translate only, and only when the server said resumable). With `reconnectWhenIdle` false
/// (dictation), a drop while no audio is in flight just closes: the server closes idle sockets after about a
/// minute, and the next press reconnects (its audio is held meanwhile).
public final class MeilingLiveSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Kind: Sendable {
        case transcribe(vocabulary: [String])
        case translate(target: String)
    }

    public enum State: Equatable, Sendable {
        case closed, connecting, ready
        case failed(String)   // retrying
        case gaveUp(String)   // stopped; open() tries again
    }

    public static let chunkSamples = 1600  // 100 ms at 16 kHz
    /// Audio this recent (or the final it is waiting for) counts as in flight: a drop then is retried.
    static let inFlightWindow: TimeInterval = 3
    public var reconnectWhenIdle = true
    static let maxPendingChunks = 100, setupTimeout: TimeInterval = 10, backoff: [TimeInterval] = [1, 4, 16]

    public let label: String
    public let queue: DispatchQueue
    public var onMessage: ((MeilingServerMessage) -> Void)?
    public var onState: ((State) -> Void)?

    private let kind: Kind
    private let apiKey: String
    private var urlSession: URLSession?  // retains us as its delegate until invalidated (close)
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var wanted = false
    private(set) public var state = State.closed { didSet { if state != oldValue { onState?(state) } } }
    private var pending: [Data] = []   // audio messages (and maybe the end) waiting for setupComplete
    private var partial: [Int16] = []
    private var resumeHandle: String?
    private var persistentFailures = 0, transientFailures = 0
    private var retry: DispatchWorkItem?
    private var readyAt: Date?  // on `queue`
    /// When setupComplete arrived (nil while not ready); read from any thread except `queue` itself.
    public var readySince: Date? { queue.sync { readyAt } }
    private var lastAudio = Date.distantPast

    public init(label: String, kind: Kind, apiKey: String) {
        self.label = label
        self.kind = kind
        self.apiKey = apiKey
        self.queue = DispatchQueue(label: "meiling.live.\(label)")
    }

    // MARK: API (any thread)

    public func open() { queue.async { self.openLocked() } }

    public func close() {
        queue.async {
            self.wanted = false
            self.retry?.cancel()
            self.teardown()
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            self.pending.removeAll()
            self.partial.removeAll()
            self.resumeHandle = nil
            self.state = .closed
        }
    }

    /// PCM16 16 kHz mono, any length: sent in 100 ms chunks.
    public func send(_ pcm: [Int16]) {
        queue.async {
            self.lastAudio = Date()
            self.partial += pcm
            while self.partial.count >= Self.chunkSamples {
                let chunk = Array(self.partial.prefix(Self.chunkSamples))
                self.partial.removeFirst(Self.chunkSamples)
                self.deliver(MeilingLiveProtocol.audioMessage(chunk))
            }
        }
    }

    /// Flushes the partial chunk, then audioStreamEnd: the model finalizes what it heard.
    public func endAudio() {
        queue.async {
            self.lastAudio = Date()
            if !self.partial.isEmpty {
                self.deliver(MeilingLiveProtocol.audioMessage(self.partial))
                self.partial.removeAll()
            }
            self.deliver(MeilingLiveProtocol.audioStreamEnd)
        }
    }

    // MARK: queue

    private func openLocked() {
        wanted = true
        switch state {
        case .connecting, .ready: return
        case .gaveUp: persistentFailures = 0; transientFailures = 0
        case .closed, .failed: break
        }
        retry?.cancel()
        connect()
    }

    private func connect() {
        guard wanted, let url = MeilingLiveProtocol.url(apiKey: apiKey) else {
            state = .gaveUp("no Gemini API key")
            return
        }
        teardown()
        generation += 1
        let gen = generation
        state = .connecting
        let session = urlSession ?? URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        let setup: Data
        switch kind {
        case let .transcribe(vocabulary): setup = MeilingLiveProtocol.transcribeSetup(vocabulary: vocabulary)
        case let .translate(target): setup = MeilingLiveProtocol.translateSetup(target: target, resumeHandle: resumeHandle)
        }
        task.send(.string(String(decoding: setup, as: UTF8.self))) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail(gen, persistent: false, "sending setup failed: \(error.localizedDescription)") }
        }
        receive(gen)
        queue.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self] in
            guard let self, self.generation == gen, self.state == .connecting else { return }
            self.fail(gen, persistent: false, "no setupComplete within 10 s")
        }
    }

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.generation == gen else { return }
                switch result {
                case let .failure(error):
                    self.fail(gen, persistent: false, "disconnected: \(error.localizedDescription)")
                case let .success(message):
                    let data: Data
                    switch message {
                    case let .data(d): data = d
                    case let .string(s): data = Data(s.utf8)
                    @unknown default: data = Data()
                    }
                    self.handle(data, gen)
                    if self.generation == gen { self.receive(gen) }
                }
            }
        }
    }

    private func handle(_ data: Data, _ gen: Int) {
        guard let m = MeilingServerMessage.parse(data) else { return }
        if let error = m.error {
            let persistent = error.localizedCaseInsensitiveContains("key") || error.localizedCaseInsensitiveContains("quota")
                || error.localizedCaseInsensitiveContains("permission")
            fail(gen, persistent: persistent, error)
            return
        }
        if m.setupComplete {
            state = .ready
            readyAt = Date()
            persistentFailures = 0
            transientFailures = 0
            let held = pending
            pending.removeAll()
            held.forEach { write($0) }
        }
        if m.resumable, !m.resumptionHandle.isEmpty { resumeHandle = m.resumptionHandle }
        onMessage?(m)
        if m.goAway, case .translate = kind {
            connect()  // with the resumption handle; held audio goes to the new socket
        }
    }

    private func deliver(_ message: Data) {
        if state == .ready {
            write(message)
            return
        }
        pending.append(message)
        if pending.count > Self.maxPendingChunks { pending.removeFirst(pending.count - Self.maxPendingChunks) }
        if case .closed = state, wanted { connect() }
    }

    private func write(_ message: Data) {
        let gen = generation
        task?.send(.string(String(decoding: message, as: UTF8.self))) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail(gen, persistent: false, "send failed: \(error.localizedDescription)") }
        }
    }

    private func fail(_ gen: Int, persistent: Bool, _ why: String) {
        guard generation == gen, wanted else { return }
        teardown()
        if !reconnectWhenIdle, !persistent, pending.isEmpty, Date().timeIntervalSince(lastAudio) > Self.inFlightWindow {
            retry?.cancel()
            state = .closed  // still wanted: the next send or open() connects again
            return
        }
        if persistent { persistentFailures += 1 } else { transientFailures += 1 }
        if persistentFailures >= 3 {
            state = .gaveUp(why)
            pending.removeAll()
            return
        }
        state = .failed(why)
        let delay = Self.backoff[min(max(persistentFailures, transientFailures) - 1, Self.backoff.count - 1)]
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func teardown() {
        generation += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        readyAt = nil
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let code = closeCode.rawValue
            // 1007 bad setup, 1008 policy (bad key / quota): retrying the same thing will not help.
            let persistent = code == 1007 || code == 1008 || (4000..<5000).contains(code)
            self.fail(self.generation, persistent: persistent, "server closed \(code) \(text)")
        }
    }
}
