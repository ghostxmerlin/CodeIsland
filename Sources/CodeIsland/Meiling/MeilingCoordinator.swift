import AppKit
import CodeIslandCore
import os.log

/// 美玲 on the Mac: decodes the Tab5's key frames, acks them with the keyboard LED, commits dictation through the
/// 美玲 input method and shows captions. See luna-work docs/superpowers/specs/2026-10-24-meiling-design.md §6.
@MainActor
final class MeilingCoordinator {
    static let shared = MeilingCoordinator()
    static let enabledKey = "meilingEnabled"

    private let assembler = MeilingFrameAssembler()
    private lazy var tap = MeilingKeyTap { [unowned self] keyCode, now in self.keyDown(keyCode, now) }
    private let ack = MeilingLedAck()
    private let switcher = MeilingInputSwitcher()
    private let ime = MeilingIMEClient()
    private var observingIME = false
    private var ticker: Timer?
    private var pendingDictation: (seq: UInt16, openedMs: UInt64)?
    private let log = MeilingLog()

    var running: Bool { tap.running }
    var lastError: String?

    func start() {
        guard !tap.running else { return }
        if !observingIME {
            MeilingAppPort.shared.addObserver { [unowned self] bundle in self.imeActivated(bundle) }
            observingIME = true
        }
        MeilingAppPort.shared.start()
        guard tap.start() else {
            lastError = "Key capture denied: allow AISM in Privacy & Security → Input Monitoring"
            log.write("tap refused")
            return
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log.write("started")
    }

    func stop() {
        tap.stop()
        ticker?.invalidate()
        ticker = nil
        if pendingDictation != nil { switcher.restore() }
        pendingDictation = nil
    }

    func ledSelfTest() -> String { ack.selfTest() }

    private static func nowMs() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }

    private func keyDown(_ keyCode: UInt16, _ now: UInt64) -> Bool {
        let result = assembler.keyDown(keyCode, atMs: now)
        handle(result.events)
        return result.swallow
    }

    private func tick() { handle(assembler.tick(atMs: Self.nowMs())) }

    private func handle(_ events: [MeilingAssemblerEvent]) {
        for event in events {
            switch event {
            case let .passThrough(keys):
                MeilingKeyTap.repost(keys)
            case .opened(.dictation):
                pendingDictation = (0, Self.nowMs())
                if switcher.meilingActive {
                    acknowledge("dictation (already active)")
                } else if !switcher.selectMeiling() {
                    log.write("dictation: Meyrin input method not installed or not enabled; no ack")
                }
            case .opened(.caption):
                acknowledge("caption")
            case let .completed(.dictation, seq, heard):
                let text = MeilingCorrectionStore.shared.apply(heard)
                // Off the key tap: the commit waits on the input method (≤1 s) and must not stall every keyboard
                // event system-wide, nor time the tap out (review I10). Commit, then restore, in order.
                pendingDictation = nil
                DispatchQueue.main.async { [self] in
                    let history = MeilingDictationHistory.shared
                    let id = history.add(text, source: "Tab5")
                    let result = ime.commit(text)
                    if result == .ok { history.mark(id, .typed) }
                    else { history.mark(id, .notTyped, note: result == .inactive ? "no text field" : "input method not responding") }
                    log.write("dictation \(seq) commit \(result) scalars=\(text.unicodeScalars.count)")
                    if result != .ok { MeilingCaptionWindow.shared.appendError("Dictation not typed: Meyrin input method \(result == .inactive ? "not active" : "not responding")") }
                    switcher.restore()
                }
            case let .completed(.caption, seq, text):
                log.write("caption \(seq) scalars=\(text.unicodeScalars.count)")
                MeilingCaptionWindow.shared.append(caption: text)
            case let .failed(kind, reason):
                log.write("frame failed \(String(describing: kind)) \(reason)")
                if kind == .dictation || pendingDictation != nil {
                    pendingDictation = nil
                    switcher.restore()
                }
                if kind == .caption { MeilingCaptionWindow.shared.appendError(reason) }
            }
        }
    }

    private func imeActivated(_ bundle: String) {
        guard let pending = pendingDictation else { return }
        acknowledge("dictation \(pending.seq) activated in \(bundle) after \(Self.nowMs() - pending.openedMs) ms")
    }

    private func acknowledge(_ what: String) {
        let ok = ack.toggle()
        log.write("ack \(what) led=\(ok ? "ok" : (ack.lastError ?? "failed"))")
    }
}

/// ~/Library/Logs/AISM/meiling.log — phases and latencies, never the dictated text.
struct MeilingLog {
    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AISM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meiling.log")
    }()

    func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
