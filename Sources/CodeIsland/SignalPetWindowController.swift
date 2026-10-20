import AppKit
import Combine
import CodeIslandCore
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "SignalPet")

/// Image view that drags its borderless window from anywhere on the pet.
private final class SignalPetImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Desktop pet: a white cat beside a railway signal whose lamp sums up every
/// session — green while agents work (or none run), blue when one waits for
/// the next instruction, red when one needs an approval/answer or failed.
///
/// Lives in its own always-on-top window, independent of the notch panel, and
/// remembers where the user dragged it.
@MainActor
final class SignalPetWindowController {
    private static let frameAutosaveName = "SignalPetWindow"
    private static let displaySize = NSSize(width: SignalPetFrame.cellWidth, height: SignalPetFrame.cellHeight)

    private let appState: AppState
    private let seenWatcher: CompletionSeenWatcher
    private var panel: NSPanel?
    private let imageView = SignalPetImageView()
    private var atlas: CGImage?
    private var frameCache: [Int: NSImage] = [:]

    private var state: SignalPetState?
    private var transition: [SignalPetFrame] = []
    private var hold: SignalPetFrame?
    private var position = 0
    private var frameTimer: Timer?
    private var animates = true
    private var isSessionObservationArmed = false
    private var gateSubscription: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        self.seenWatcher = CompletionSeenWatcher(appState: appState)
    }

    func show() {
        guard panel == nil else { return }
        guard let atlas = Self.loadAtlas() else {
            log.error("white-cat-signal atlas missing from resources; desktop pet disabled")
            return
        }
        self.atlas = atlas

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.displaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: Self.displaySize)
        panel.contentView = imageView

        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setFrameOrigin(Self.defaultOrigin())
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        panel.orderFrontRegardless()
        self.panel = panel

        let gate = MascotAnimationGate.shared
        gateSubscription = gate.$isAwake.combineLatest(gate.$reduceMotion)
            .sink { [weak self] awake, reduceMotion in
                Task { @MainActor in
                    guard let self else { return }
                    self.animates = awake && !reduceMotion
                    if !self.animates { self.finishTransition() }
                }
            }

        updateState()
        armSessionObservation()
    }

    // MARK: - State

    /// `withObservationTracking` is one-shot; re-arm from `onChange` like the
    /// notch panel does, so an idle app schedules no work.
    private func armSessionObservation() {
        guard !isSessionObservationArmed else { return }
        isSessionObservationArmed = true
        withObservationTracking {
            _ = appState.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSessionObservationArmed = false
                self.updateState()
                self.armSessionObservation()
            }
        }
    }

    private func updateState() {
        seenWatcher.sessionsChanged()
        let next = SignalPetState.resolve(appState.sessions.values)
        guard next != state else { return }
        let animated = animates && SignalPetAnimation.animatesTransition(from: state, to: next)
        state = next
        show(next, animated: animated)
    }

    // MARK: - Playback

    /// Plays the state's row once when the lamp changed, then holds still.
    private func show(_ state: SignalPetState, animated: Bool) {
        frameTimer?.invalidate()
        frameTimer = nil
        let timeline = SignalPetAnimation.timeline(for: state)
        hold = timeline.hold
        transition = animated ? timeline.transition : []
        position = 0
        advance()
    }

    private func advance() {
        guard position < transition.count else {
            finishTransition()
            return
        }
        let frame = transition[position]
        position += 1
        display(frame)
        frameTimer = Timer.scheduledTimer(withTimeInterval: Double(frame.durationMs) / 1000, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.advance()
            }
        }
    }

    private func finishTransition() {
        frameTimer?.invalidate()
        frameTimer = nil
        transition = []
        if let hold { display(hold) }
    }

    private func display(_ frame: SignalPetFrame) {
        let key = frame.row * 100 + frame.column
        if let cached = frameCache[key] {
            imageView.image = cached
            return
        }
        let rect = CGRect(origin: frame.cellOrigin, size: CGSize(width: SignalPetFrame.cellWidth, height: SignalPetFrame.cellHeight))
        guard let cell = atlas?.cropping(to: rect) else { return }
        let image = NSImage(cgImage: cell, size: Self.displaySize)
        frameCache[key] = image
        imageView.image = image
    }

    // MARK: - Resources & placement

    private static func loadAtlas() -> CGImage? {
        let url = Bundle.appModule.url(forResource: "white-cat-signal", withExtension: "png", subdirectory: "Resources")
            ?? Bundle.appModule.url(forResource: "white-cat-signal", withExtension: "png")
        // ImageIO keeps the atlas at its pixel size; cell rects are in pixels.
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Bottom-right corner of the main screen, clear of the Dock.
    private static func defaultOrigin() -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(x: visible.maxX - displaySize.width - 24, y: visible.minY + 24)
    }
}
