import AppKit
import SwiftUI

/// 美玲 (Tab5 hardware mode) floating caption window: the owner's translated line (large) with the original (small), always on top,
/// visible in screen sharing. Captions arrive as "<translation>\n<original>".
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
        @Published var fontSize: Double = UserDefaults.standard.double(forKey: "meilingCaptionFont").nonZero ?? 28
    }

    static let shared = MeilingCaptionWindow()
    static let maxLines = 6
    let model = Model()
    private var panel: NSPanel?

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
        show()
    }

    func changeFont(by delta: Double) {
        model.fontSize = min(64, max(14, model.fontSize + delta))
        UserDefaults.standard.set(model.fontSize, forKey: "meilingCaptionFont")
    }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 200, y: 120, width: 900, height: 220),
                            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "Meyrin Captions (Tab5)"
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .statusBar
            p.sharingType = .readOnly
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = NSColor.black.withAlphaComponent(0.72)
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: CaptionView(model: model))
            p.setFrameAutosaveName("MeilingCaptionWindow")
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    private struct CaptionView: View {
        @ObservedObject var model: Model
        var body: some View {
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
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
