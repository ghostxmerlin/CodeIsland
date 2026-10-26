import AppKit
import CodeIslandCore
import SwiftUI

/// The card shown while Luna speaks, as on the Tab5 (home_view showVoiceLine): her avatar, the Japanese line and
/// its Chinese gloss. Top right under the menu bar, where macOS notifications appear (the Meyrin HUD holds the top
/// centre); it never takes focus or clicks, slides in when a line starts and leaves shortly after the last one.
@MainActor
final class LunaVoiceCard {
    static let shared = LunaVoiceCard()

    final class Model: ObservableObject {
        @Published var line: LunaLine?
        @Published var visible = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private static let size = NSSize(width: 400, height: 96)

    private lazy var avatar: NSImage? = Bundle.appModule.url(forResource: "luna-avatar", withExtension: "png",
                                                             subdirectory: "Resources/LunaVoice")
        .flatMap(NSImage.init(contentsOf:))

    func show(_ line: LunaLine) {
        hide?.cancel()
        model.line = line
        let panel = self.panel ?? makePanel()
        if let screen = IslandScreen.current {  // the island's display, not the focused one
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - Self.size.width - 16, y: f.maxY - Self.size.height - 8))
        }
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.25)) { model.visible = true }
    }

    /// The line ended: the card stays a moment so the text can be read, then slides out.
    func finished() {
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.model.visible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.model.visible else { return }
                self.panel?.orderOut(nil)
            }
        }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: CardView(model: model, avatar: avatar))
        panel = p
        return p
    }

    private struct CardView: View {
        @ObservedObject var model: Model
        let avatar: NSImage?

        var body: some View {
            HStack(spacing: 12) {
                Group {
                    if let avatar {
                        Image(nsImage: avatar).resizable().scaledToFill()
                    } else {
                        Color.gray
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(red: 0.85, green: 0.25, blue: 0.35), lineWidth: 2))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.line?.ja ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(model.line?.zh ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: LunaVoiceCard.size.width, height: LunaVoiceCard.size.height)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.04, green: 0.09, blue: 0.14).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 0.85, green: 0.25, blue: 0.35).opacity(0.8), lineWidth: 1.5))
            .opacity(model.visible ? 1 : 0)
            .offset(x: model.visible ? 0 : 40)
        }
    }
}
