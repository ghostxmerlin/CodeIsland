import AppKit

extension UserDefaults {
    @objc dynamic var showSignalPet: Bool {
        bool(forKey: SettingsKey.showSignalPet)
    }
}

/// What `SignalPetSwitch` puts on screen; tests stand in a fake.
@MainActor
protocol SignalPetPresenting: AnyObject {
    func show()
    func hide()
}

/// Keeps the desktop signal-cat in step with Settings → General → Desktop
/// Pet while the app runs. Turning it off tears the pet down; turning it back
/// on builds a fresh one, which resolves the current lamp from scratch.
@MainActor
final class SignalPetSwitch {
    private let defaults: UserDefaults
    private let makePet: () -> SignalPetPresenting
    private var pet: SignalPetPresenting?
    private var observation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard, makePet: @escaping () -> SignalPetPresenting) {
        self.defaults = defaults
        self.makePet = makePet
    }

    func start() {
        sync()
        observation = defaults.observe(\.showSignalPet, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.sync() }
        }
    }

    private func sync() {
        if defaults.bool(forKey: SettingsKey.showSignalPet) {
            guard pet == nil else { return }
            let pet = makePet()
            pet.show()
            self.pet = pet
        } else {
            pet?.hide()
            pet = nil
        }
    }
}
