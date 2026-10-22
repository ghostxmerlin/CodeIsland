import AppKit
import ApplicationServices
import Observation

extension UserDefaults {
    @objc dynamic var buddyFingerprintUnlockEnabled: Bool {
        bool(forKey: SettingsKey.fingerprintUnlockEnabled)
    }
}

/// The real Mac behind `FingerprintUnlockController`.
@MainActor
final class LiveFingerprintUnlockSystem: FingerprintUnlockSystem {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.bool(forKey: SettingsKey.fingerprintUnlockEnabled) }
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    func lockState() -> Bool? { LockScreen.state() }
    func hasPassword() -> Bool { UnlockPasswordStore.hasPassword() }
    func readPassword() throws -> Data { try UnlockPasswordStore.read() }
    func typePassword(_ password: Data) throws { try LockScreen.enter(password) }
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Runs fingerprint unlock while the app is up. The lock state is polled
/// only from a screen-lock (or wake) notification until the screen is
/// unlocked again, so an unlocked Mac pays nothing for it: every 0.25 s
/// while a round runs or just after the notification, every 1 s otherwise.
@MainActor
@Observable
final class FingerprintUnlockService {
    static let shared = FingerprintUnlockService()

    private static let fastPollInterval: TimeInterval = 0.25
    private static let slowPollInterval: TimeInterval = 1
    /// The session can still read unlocked for a moment after the lock
    /// notification; keep polling at least this long before giving up.
    private static let graceSeconds: TimeInterval = 5

    let controller: FingerprintUnlockController

    @ObservationIgnored private let system: LiveFingerprintUnlockSystem
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: TimeInterval = 0
    @ObservationIgnored private var graceUntil: TimeInterval = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var enabledObservation: NSKeyValueObservation?
    /// Held strongly so a reconnect's new channel can't reuse its address.
    @ObservationIgnored private var lastDevice: BuddyFingerprintChannel?

    private init() {
        let system = LiveFingerprintUnlockSystem()
        self.system = system
        controller = FingerprintUnlockController(system: system) { Self.unlockDevice() }
    }

    /// Phase 1 challenges a single Atom: the first one that can unlock.
    static func unlockDevice() -> BuddyFingerprintChannel? {
        ESP32BridgeManager.shared.fingerprintChannels.first { $0.canUnlock }
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.startPolling() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.poll() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidWakeNotification) { service in
            service.controller.screenDidWake()
            service.startPolling()
        }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.controller.systemWillSleep() }
        enabledObservation = UserDefaults.standard.observe(\.buddyFingerprintUnlockEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.enabledDidChange() }
        }
        startPolling()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (FingerprintUnlockService) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func enabledDidChange() {
        if system.isEnabled {
            startPolling()
        } else {
            controller.settingDidTurnOff()
        }
    }

    private func startPolling() {
        graceUntil = system.now() + Self.graceSeconds
        poll()
    }

    private func poll() {
        let device = Self.unlockDevice()
        if let device, device !== lastDevice {
            if lastDevice != nil { controller.deviceDidReconnect() }
            lastDevice = device
        }
        let locked = controller.tick()
        let inGrace = system.now() < graceUntil
        if controller.isBusy || inGrace {
            schedule(every: Self.fastPollInterval)
        } else if system.isEnabled && locked == true {
            schedule(every: Self.slowPollInterval)
        } else {
            // Unlocked, unknown (e.g. fast user switching) or turned off:
            // the next lock or wake notification starts polling again.
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule(every interval: TimeInterval) {
        guard timer == nil || timerInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval
    }
}
