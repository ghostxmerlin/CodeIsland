import AppKit
import SwiftUI

/// 美玲 floating caption window: the translated line (large) with the original (small), always on top.
/// `shared` is the owner's side, visible in screen sharing; `theirs` is the other side (Mac-only meeting mode),
/// hidden from screen sharing. Captions from the Tab5 arrive as "<translation>\n<original>".
@MainActor
final class MeilingCaptionWindow {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let original: String
        let error: Bool
    }

    final class Model: ObservableObject {
        @Published var lines: [Line] = []
        @Published var pending: Line?
        @Published var fontSize: Double
        init(fontSize: Double) { self.fontSize = fontSize }
    }

    static let shared = MeilingCaptionWindow()
    static let theirs = MeilingCaptionWindow(title: "Their Captions (hidden from screen sharing)", key: "meilingTheirCaption", shareable: false)
    static let maxLines = 6
    let model: Model
    private var panel: NSPanel?
    private let title: String, key: String, shareable: Bool
    /// Closed by the owner: new lines no longer bring it back until `show()` (menu, Settings, the next meeting).
    private var dismissed = false

    init(title: String = "Meyrin Captions", key: String = "meilingCaption", shareable: Bool = true) {
        self.title = title
        self.key = key
        self.shareable = shareable
        model = Model(fontSize: UserDefaults.standard.double(forKey: key + "Font").nonZero ?? 28)
    }

    func append(text: String, original: String) {
        model.pending = nil
        push(Line(text: text, original: original, error: false))
    }

    /// The line still being assembled, shown dimmed under the finished ones.
    func setPending(text: String, original: String) {
        model.pending = Line(text: text, original: original, error: false)
        reveal()
    }

    func append(caption: String) {
        let parts = caption.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        push(Line(text: String(parts.first ?? ""), original: parts.count > 1 ? String(parts[1]) : "", error: false))
    }

    func appendError(_ reason: String) {
        push(Line(text: "Transfer error (\(reason))", original: "", error: true))
    }

    private func push(_ line: Line) {
        model.lines.append(line)
        if model.lines.count > Self.maxLines { model.lines.removeFirst(model.lines.count - Self.maxLines) }
        reveal()
    }

    func changeFont(by delta: Double) {
        model.fontSize = min(64, max(14, model.fontSize + delta))
        UserDefaults.standard.set(model.fontSize, forKey: key + "Font")
    }

    /// A new line arrived: show the window unless the owner closed it.
    private func reveal() {
        guard !dismissed else { return }
        show()
    }

    /// Hides without counting as closed by the owner (the meeting ended).
    func hide() {
        panel?.orderOut(nil)
        dismissed = false
    }

    func show() {
        dismissed = false
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 200, y: 120, width: 900, height: 220),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = title
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .statusBar
            p.sharingType = shareable ? .readOnly : .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = NSColor.black.withAlphaComponent(0.72)
            p.isReleasedWhenClosed = false
            p.contentView = FirstClickHostingView(rootView: CaptionView(model: model, showHistory: shareable))
            p.setFrameAutosaveName(key == "meilingCaption" ? "MeilingCaptionWindow" : key + "Window")
            if !shareable, p.frame.origin == NSPoint(x: 200, y: 120) { p.setFrameOrigin(NSPoint(x: 200, y: 360)) }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissed = true }
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    private struct CaptionView: View {
        @ObservedObject var model: Model
        let showHistory: Bool  // the owner's window (Tab5 dictation errors land here); not the other side's
        var body: some View {
            content.overlay(alignment: .topTrailing) {
                if showHistory {
                    Button { MeilingHistoryWindow.shared.show() } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("Dictation history: every sentence, including ones that were not typed")
                    .padding(8)
                }
            }
        }

        private var content: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.system(size: model.fontSize, weight: .semibold))
                            .foregroundColor(line.error ? .red : .white)
                        if !line.original.isEmpty {
                            Text(line.original)
                                .font(.system(size: model.fontSize * 0.55))
                                .foregroundColor(.gray)
                        }
                    }
                }
                if let pending = model.pending {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.text.isEmpty ? "…" : pending.text)
                            .font(.system(size: model.fontSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                        if !pending.original.isEmpty {
                            Text(pending.original)
                                .font(.system(size: model.fontSize * 0.55))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
