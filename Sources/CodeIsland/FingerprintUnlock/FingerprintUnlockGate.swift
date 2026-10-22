/// Lets one unlock round through per arming: challenge once the screen is
/// seen locked, fire once the answer is verified, stop if the screen is
/// unlocked some other way or its state can't be read. Ported from exia's
/// ProbeGate without the 90 s limit — aism waits for a finger indefinitely.
struct FingerprintUnlockGate {
    enum Action: Equatable {
        case wait
        case challenge
        case fire
        case stop
    }

    private(set) var active = false
    private var sawLocked = false
    private var challenged = false

    mutating func arm() {
        active = true
        sawLocked = false
        challenged = false
    }

    mutating func cancel() { active = false }

    /// The round failed on the device side (wrong answer, error, link lost).
    mutating func fail() { active = false }

    mutating func step(locked: Bool?, verified: Bool) -> Action {
        guard active else { return .wait }
        guard let locked else {
            active = false
            return .stop
        }
        if !locked {
            if sawLocked {
                active = false
                return .stop
            }
            return .wait
        }
        sawLocked = true
        if verified {
            active = false
            return .fire
        }
        if !challenged {
            challenged = true
            return .challenge
        }
        return .wait
    }
}
