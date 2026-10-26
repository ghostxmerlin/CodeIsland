import AppKit
import SwiftUI

/// A small non-activating pill at the top centre of the screen while 美玲 listens: state, the interim half sentence
/// (grey), the last sentence put at the cursor (green), or the error (red). It never takes focus, so the cursor
/// stays where the text goes. Its History button opens the dictation history; it stays up while the pointer is
/// over it.
@MainActor
final class MeilingSoftHUD {
    final class Model: ObservableObject {
        @Published var title = ""
        @Published var live = false
        @Published var interim = ""
        @Published var committed = ""
        @Published var error = ""
        @Published var errorIsNotice = false  // information (white), not a failure (red)
        @Published var startedAt: Date?
        @Published var level: Float = 0   // the mic's input level, 0…1
        @Published var micName = ""
    }

    static let shared = MeilingSoftHUD()
    let model = Model()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    /// The microphone being listened to and its live level (the meter shows only while listening).
    func mic(_ name: String) { model.micName = name }
    func level(_ value: Float) { if model.live { model.level = value } }

    func listening(_ title: String) {
        model.title = title
        model.level = 0
        model.live = true
        model.interim = ""
        model.error = ""
        model.startedAt = Date()
        show(autoHide: false)
    }

    func stopped() {
        model.live = false
        model.startedAt = nil
        show(autoHide: true)
    }

    func interim(_ text: String) {
        model.interim = text
        show(autoHide: !model.live)
    }

    func committed(_ text: String) {
        model.committed = text
        model.interim = ""
        show(autoHide: !model.live)
    }

    func error(_ text: String) {
        model.error = text
        model.errorIsNotice = false
        show(autoHide: !model.live, after: 6)
    }

    /// Information for the owner (what to pick, wait a moment): shown like an error but not in red.
    func notice(_ text: String) {
        model.error = text
        model.errorIsNotice = true
        show(autoHide: !model.live, after: 6)
    }

    private func show(autoHide: Bool, after: TimeInterval = 2.5) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 96),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = false  // the History button; a non-activating panel leaves the cursor's app active
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.sharingType = .none
            p.contentView = FirstClickHostingView(rootView: HUDView(model: model))
            panel = p
        }
        // Top centre, just under the menu bar where the island's dialogs open: at the bottom it covered the
        // terminal's input line (owner 2026-10-26).
        if let screen = IslandScreen.current, let panel {  // the island's display, not the focused one
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 8))
        }
        panel?.orderFrontRegardless()
        hide?.cancel()
        guard autoHide else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The pointer's real position: hover events do not reliably reach a panel that never becomes key.
            if let frame = self.panel?.frame, frame.contains(NSEvent.mouseLocation) {
                self.show(autoHide: true, after: 1)  // reading or about to click: hide once the pointer leaves
            } else {
                self.panel?.orderOut(nil)
            }
        }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
    }

    private struct HUDView: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(model.live ? Color.red : Color.gray).frame(width: 10, height: 10)
                    Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    if let started = model.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            let s = Int(context.date.timeIntervalSince(started))
                            Text(String(format: "%d:%02d", s / 60, s % 60))
                                .font(.system(size: 13, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    if model.live, !model.micName.isEmpty {
                        Image(systemName: "mic.fill").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                        Text(model.micName)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 170, alignment: .trailing)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            Capsule().fill(model.level > 0.85 ? Color.orange : Color.green)
                                .frame(width: 70 * CGFloat(model.level))
                        }
                        .frame(width: 70, height: 6)
                        .help("Microphone level: it should move while you talk")
                    }
                    Button {
                        MeilingHistoryWindow.shared.show()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("Dictation history: every sentence, including ones that were not typed")
                }
                if !model.error.isEmpty {
                    Text(model.error).font(.system(size: 14)).foregroundColor(model.errorIsNotice ? .white : .red).lineLimit(2)
                }
                if !model.interim.isEmpty {
                    Text(model.interim).font(.system(size: 15)).foregroundColor(.white.opacity(0.55)).lineLimit(2)
                } else if !model.committed.isEmpty {
                    Text(model.committed).font(.system(size: 15)).foregroundColor(.green).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 640, height: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.78)))
        }
    }
}

/// The HUD never becomes key, so the first click must reach its button directly.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
