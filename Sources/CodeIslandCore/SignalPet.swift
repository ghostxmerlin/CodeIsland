import CoreGraphics

/// Lamp lit on the desktop signal-cat's railway signal.
public enum SignalLamp: Sendable, Equatable {
    case green
    case blue
    case red
}

/// What the desktop signal-cat shows for all sessions combined.
public enum SignalPetState: Sendable, Equatable {
    /// No agents, or every agent is busy — nothing for the user to do.
    case working
    /// An agent finished a turn the user has not looked at yet.
    case awaitingInput
    /// An agent stopped mid-task on an approval or a question.
    case needsAttention
    /// An agent's last turn ended on an error the user has not looked at yet.
    case failed

    public var lamp: SignalLamp {
        switch self {
        case .working: return .green
        case .awaitingInput: return .blue
        case .needsAttention, .failed: return .red
        }
    }

    /// Most urgent wins: pending request > unseen failed turn > unseen finished
    /// turn > working. A finished turn the user already looked at counts as
    /// nothing to do, so a session left parked does not hold the lamp.
    public static func resolve<C: Collection>(_ sessions: C) -> SignalPetState where C.Element == SessionSnapshot {
        if sessions.contains(where: { $0.status == .waitingApproval || $0.status == .waitingQuestion }) {
            return .needsAttention
        }
        let unseenFinished = sessions.filter { $0.status == .idle && $0.completionUnseen }
        if unseenFinished.contains(where: { $0.lastTurnFailed }) {
            return .failed
        }
        if !unseenFinished.isEmpty {
            return .awaitingInput
        }
        return .working
    }
}

/// One cell of the white-cat-signal sprite atlas (8 × 11 grid of 192 × 208 cells).
public struct SignalPetFrame: Sendable, Equatable {
    public static let cellWidth = 192
    public static let cellHeight = 208

    public let row: Int
    public let column: Int
    public let durationMs: Int

    public init(row: Int, column: Int, durationMs: Int) {
        self.row = row
        self.column = column
        self.durationMs = durationMs
    }

    public var cellOrigin: CGPoint {
        CGPoint(x: column * Self.cellWidth, y: row * Self.cellHeight)
    }
}

/// Atlas rows and per-frame durations, from the asset package's integration.json.
public enum SignalPetAnimation {
    /// The cat holds still: looping rows drift a pixel or two between frames,
    /// which reads as jitter on the desktop. A row plays once when the lamp
    /// changes, then the cat freezes on `hold`.
    public struct Timeline: Sendable, Equatable {
        /// Played once when the lamp changes into this state.
        public let transition: [SignalPetFrame]
        /// Shown for as long as the state lasts.
        public let hold: SignalPetFrame
    }

    static func row(_ row: Int, _ durations: [Int]) -> [SignalPetFrame] {
        durations.enumerated().map { SignalPetFrame(row: row, column: $0.offset, durationMs: $0.element) }
    }

    static let idle = row(0, [280, 110, 110, 140, 140, 320])
    static let waving = row(3, [140, 140, 140, 280])
    static let failed = row(5, [140, 140, 140, 140, 140, 140, 140, 240])
    static let waiting = row(6, [150, 150, 150, 150, 150, 260])
    static let running = row(7, [120, 120, 120, 120, 120, 220])

    public static func timeline(for state: SignalPetState) -> Timeline {
        switch state {
        case .working: return Timeline(transition: running, hold: running[0])
        // Wave the user over once, then doze until they answer.
        case .awaitingInput: return Timeline(transition: waving, hold: idle[0])
        case .needsAttention: return Timeline(transition: waiting, hold: waiting[0])
        case .failed: return Timeline(transition: failed, hold: failed[0])
        }
    }

    /// Only a lamp change moves the cat; the state shown at launch, or a
    /// switch between two states on the same lamp, just swaps the still frame.
    public static func animatesTransition(from old: SignalPetState?, to new: SignalPetState) -> Bool {
        guard let old else { return false }
        return old.lamp != new.lamp
    }
}
