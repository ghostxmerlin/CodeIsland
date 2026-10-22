import CoreBluetooth
import Foundation
import Observation
import os
import Security
import CodeIslandCore

/// Connection lifecycle state for the Buddy Bluetooth bridge. Each selected
/// Buddy has its own link state; the bridge-level `status` folds them together.
enum ESP32BridgeStatus: Equatable {
    case off                  // user has disabled the bridge
    case poweredOff           // Bluetooth radio is off / unauthorized / unsupported
    case noSelection          // no Buddy has been selected yet
    case scanning             // discovery mode: enumerating nearby Buddies for the user
    case searchingSelected    // looking for the previously-selected Buddy
    case connecting           // found the selected one, connecting / discovering characteristics
    case pairing              // BLE connected, pair request sent, waiting for Buddy response
    case pairWaitingConfirm   // Buddy shows confirmation screen, waiting for user button press
    case pairRejected         // Buddy rejected pairing or pairing timed out
    case connected            // ready to write + receiving notifications
    case reconnecting(Int)    // seconds until next attempt to find the selected Buddy

    var shortDescription: String {
        switch self {
        case .off:                return "off"
        case .poweredOff:         return "bluetooth off"
        case .noSelection:        return "no selection"
        case .scanning:           return "scanning"
        case .searchingSelected:  return "searching selected"
        case .connecting:         return "connecting"
        case .pairing:            return "pairing"
        case .pairWaitingConfirm: return "confirm on Buddy"
        case .pairRejected:       return "pair rejected"
        case .connected:          return "connected"
        case .reconnecting(let s): return "reconnecting in \(s)s"
        }
    }

    /// How far a single Buddy link has come; bridge-level states rank lowest.
    private var linkProgress: Int {
        switch self {
        case .connected:          return 7
        case .pairWaitingConfirm: return 6
        case .pairing:            return 5
        case .connecting:         return 4
        case .searchingSelected:  return 3
        case .reconnecting:       return 2
        case .pairRejected:       return 1
        case .off, .poweredOff, .noSelection, .scanning: return 0
        }
    }

    /// Fold per-Buddy link states into one: the most advanced link wins, so a
    /// single connected Buddy makes the bridge read as connected.
    static func aggregate(_ statuses: [ESP32BridgeStatus]) -> ESP32BridgeStatus? {
        statuses.max { lhs, rhs in
            if lhs.linkProgress != rhs.linkProgress {
                return lhs.linkProgress < rhs.linkProgress
            }
            if case .reconnecting(let l) = lhs, case .reconnecting(let r) = rhs {
                return l > r
            }
            return false
        }
    }
}

/// One Buddy peripheral seen during discovery.
struct DiscoveredBuddy: Identifiable, Equatable {
    let id: UUID            // CBPeripheral.identifier (stable per Mac)
    var name: String
    var rssi: Int
    var lastSeen: Date
}

/// A Buddy the user picked, persisted across launches.
struct BuddySelection: Equatable {
    let id: UUID
    var name: String?
}

/// Reads and writes the selected Buddies. The list lives under
/// `SettingsKey.selectedBuddies`; the pre-multi-Buddy single-selection keys
/// are migrated on first load and kept mirroring the first entry.
enum BuddySelectionStore {
    private static let idField = "id"
    private static let nameField = "name"

    static func load(from defaults: UserDefaults) -> [BuddySelection] {
        if let entries = defaults.array(forKey: SettingsKey.selectedBuddies) {
            var result: [BuddySelection] = []
            for case let entry as [String: String] in entries {
                guard let raw = entry[idField],
                      let id = UUID(uuidString: raw),
                      !result.contains(where: { $0.id == id }) else { continue }
                let name = entry[nameField].flatMap { $0.isEmpty ? nil : $0 }
                result.append(BuddySelection(id: id, name: name))
            }
            return result
        }
        guard let raw = defaults.string(forKey: SettingsKey.selectedBuddyIdentifier),
              let id = UUID(uuidString: raw) else { return [] }
        let name = defaults.string(forKey: SettingsKey.selectedBuddyName).flatMap { $0.isEmpty ? nil : $0 }
        return [BuddySelection(id: id, name: name)]
    }

    static func save(_ selections: [BuddySelection], to defaults: UserDefaults) {
        let entries: [[String: String]] = selections.map { selection in
            var entry = [idField: selection.id.uuidString]
            if let name = selection.name { entry[nameField] = name }
            return entry
        }
        defaults.set(entries, forKey: SettingsKey.selectedBuddies)
        if let first = selections.first {
            defaults.set(first.id.uuidString, forKey: SettingsKey.selectedBuddyIdentifier)
            if let name = first.name {
                defaults.set(name, forKey: SettingsKey.selectedBuddyName)
            } else {
                defaults.removeObject(forKey: SettingsKey.selectedBuddyName)
            }
        } else {
            defaults.removeObject(forKey: SettingsKey.selectedBuddyIdentifier)
            defaults.removeObject(forKey: SettingsKey.selectedBuddyName)
        }
    }
}

private enum PendingResponseWrite {
    case pairRequest
    case unpair
}

/// One selected Buddy and its BLE link: its own connection, pairing
/// handshake, write queue and reconnect backoff. Every connected link
/// receives the same frames.
@MainActor
@Observable
final class BuddyLink: Identifiable {
    let id: UUID
    fileprivate(set) var name: String?
    fileprivate(set) var status: ESP32BridgeStatus = .searchingSelected
    fileprivate(set) var lastError: String?
    fileprivate(set) var usesLegacyPairingFallback = false
    /// Fingerprint channel while this link is paired; `nil` before pairing
    /// and on legacy firmware.
    fileprivate(set) var fingerprint: BuddyFingerprintChannel?

    var displayName: String { name ?? id.uuidString }

    @ObservationIgnored fileprivate var peripheral: CBPeripheral?
    @ObservationIgnored fileprivate var writeChar: CBCharacteristic?
    @ObservationIgnored fileprivate var notifyChar: CBCharacteristic?
    @ObservationIgnored fileprivate var notifySubscriptionReady = false
    @ObservationIgnored fileprivate var reconnectAttempt = 0
    @ObservationIgnored fileprivate var reconnectTimer: Timer?
    /// Fires after `pairConfirmTimeoutSeconds` while Buddy is waiting for BOOT confirmation.
    @ObservationIgnored fileprivate var pairTimeoutTimer: Timer?
    /// Fires when no pair response arrives after the request write is delivered.
    @ObservationIgnored fileprivate var pairResponseTimer: Timer?
    @ObservationIgnored fileprivate var pairResponseAllowsLegacyFallback = false
    @ObservationIgnored fileprivate var pendingResponseWrite: PendingResponseWrite?
    /// Set while the unpair write is in flight so the disconnect callback
    /// finishes the forget instead of scheduling a reconnect.
    @ObservationIgnored fileprivate var forgetting = false
    @ObservationIgnored fileprivate var writeQueue = BuddyWriteQueue(capacity: BuddyLink.maxPendingWriteFrames)

    fileprivate static let maxPendingWriteFrames = 64

    fileprivate init(selection: BuddySelection) {
        id = selection.id
        name = selection.name
    }

    fileprivate var selection: BuddySelection { BuddySelection(id: id, name: name) }

    fileprivate func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    fileprivate func cancelPairTimeout() {
        pairTimeoutTimer?.invalidate()
        pairTimeoutTimer = nil
    }

    fileprivate func cancelPairResponseTimeout() {
        pairResponseTimer?.invalidate()
        pairResponseTimer = nil
        pairResponseAllowsLegacyFallback = false
    }

    fileprivate func cancelPairingTimers() {
        cancelPairTimeout()
        cancelPairResponseTimeout()
    }

    /// Drop everything tied to the current GATT connection.
    fileprivate func clearConnection() {
        fingerprint?.connectionDropped()
        fingerprint = nil
        cancelPairingTimers()
        pendingResponseWrite = nil
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        notifySubscriptionReady = false
        writeQueue.removeAll(keepingCapacity: false)
        usesLegacyPairingFallback = false
    }
}

/// CoreBluetooth central that talks to Buddy LCD companions.
///
/// Each firmware advertises a unique `Buddy-XXXXXX` name based on its chipId.
/// The user can select several; each selected Buddy gets its own `BuddyLink`
/// and every connected link receives the same standard Buddy protocol frames.
/// Selections are persisted to UserDefaults and auto-reconnected on launch;
/// unselected Buddies in range are ignored.
///
/// Streaming writes use `.withoutResponse`; pairing uses `.withResponse` when
/// the firmware advertises `WRITE`, so delivery failures don't look like legacy firmware.
/// The notify characteristic delivers 1-byte button events carrying the
/// currently displayed mascot's `sourceId` – dispatched to
/// `ESP32FocusCoordinator`, whichever Buddy sent them.
@MainActor
@Observable
final class ESP32BridgeManager: NSObject {
    static let shared = ESP32BridgeManager()

    private static let log = Logger(subsystem: "com.codeisland", category: "esp32-bridge")

    // Observable for SettingsView
    /// Bluetooth radio problem (off / denied / unsupported); per-Buddy
    /// problems live on each `BuddyLink`.
    private(set) var lastError: String?
    private(set) var discovered: [DiscoveredBuddy] = []
    /// Selected Buddies, in the order the user picked them.
    private(set) var links: [BuddyLink] = []
    private(set) var isDiscovering = false

    private var started = false
    private var radioState: CBManagerState = .unknown

    var status: ESP32BridgeStatus {
        guard started else { return .off }
        guard radioState == .poweredOn else { return .poweredOff }
        if let linkStatus = ESP32BridgeStatus.aggregate(links.map(\.status)) {
            return linkStatus
        }
        return isDiscovering ? .scanning : .noSelection
    }

    var hasSelection: Bool { !links.isEmpty }

    /// True when any connected Buddy runs firmware without pairing support.
    var usesLegacyPairingFallback: Bool {
        links.contains { $0.usesLegacyPairingFallback }
    }

    func isSelected(_ buddyId: UUID) -> Bool {
        links.contains { $0.id == buddyId }
    }

    // Backoff table (seconds) mirrors Buddy's 1→2→4→8→…30 exponential.
    private static let reconnectBackoff: [Int] = [1, 2, 4, 8, 16, 30]

    /// Discovery entries older than this without a re-advertisement get pruned.
    private static let discoveryStaleSeconds: TimeInterval = 10

    private var central: CBCentralManager?
    private var discoveryPruneTimer: Timer?
    /// Stable 6-byte identifier for this Mac, used in the application-layer
    /// pairing handshake so Buddy can distinguish paired hosts. The same id
    /// goes to every Buddy, so each one pairs with this Mac independently.
    @ObservationIgnored
    private var hostIdentifier: Data = loadOrCreateHostId()
    /// CoreBluetooth can keep an existing manager in `.unauthorized` after the
    /// user flips macOS Bluetooth permission back to allowed. Recreate it once
    /// in that case so the app can recover without a full relaunch.
    private var authorizationRecoveryResetAttempted = false

    /// Callback fired when a Buddy notifies a button press with a
    /// mascot `sourceId` byte. Nonisolated to allow CoreBluetooth delegate
    /// callbacks to forward to `@MainActor` consumers.
    var onFocusRequest: ((MascotID) -> Void)?

    /// Callback fired when a Buddy sends a control opcode from a watch
    /// notification action.
    var onControlCommand: ((BuddyControlCommand) -> Void)?

    /// Callback fired right after any Buddy reaches `.connected`, so the
    /// publisher can push the current frame immediately (don't wait for the
    /// next heartbeat tick).
    var onConnected: (() -> Void)?

    private let defaults = UserDefaults.standard

    private override init() {
        super.init()
        links = BuddySelectionStore.load(from: defaults).map(BuddyLink.init(selection:))
    }

    // MARK: - Public lifecycle

    /// Enable the bridge. Lazily creates the `CBCentralManager` (which triggers
    /// the system Bluetooth permission prompt on first run). Auto-reconnects to
    /// every selected Buddy; with none selected it sits in `.noSelection`
    /// waiting for the user to pick from the settings page.
    func start() {
        guard !started else { return }
        started = true
        lastError = nil
        ensureCentral()
        reconnectIdleLinks()
    }

    /// Disable the bridge, tear down every link + scan + discovery.
    func stop() {
        stopDiscoveryInternal(resumeLinks: false)
        if let central, central.isScanning { central.stopScan() }
        for link in links {
            link.cancelReconnectTimer()
            if let peripheral = link.peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            resetLink(link)
        }
        central?.delegate = nil
        central = nil
        radioState = .unknown
        authorizationRecoveryResetAttempted = false
        started = false
    }

    /// Enter discovery mode: continuously scan for nearby Buddies and populate
    /// `discovered` so the settings UI can offer them as choices. Does NOT
    /// auto-connect – call `select(buddyId:)` to commit.
    func startDiscovery() {
        ensureCentral()
        guard let central else { return }
        isDiscovering = true
        if central.state == .poweredOn {
            // allowDuplicates so RSSI updates live in the UI.
            let serviceUUID = CBUUID(string: ESP32Protocol.serviceUUID)
            central.scanForPeripherals(withServices: [serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            Self.log.info("Discovery scan started")
        }
        startDiscoveryPruneTimer()
    }

    /// Exit discovery mode. Returns the central to a directed reconnect scan
    /// (if a selected Buddy is still missing) or idle.
    func stopDiscovery() {
        stopDiscoveryInternal(resumeLinks: true)
    }

    /// Add a Buddy to the selection and connect to it. Picking one that is
    /// already selected retries it, which also clears a rejected pairing.
    func select(buddyId: UUID) {
        let discoveredName = discovered.first(where: { $0.id == buddyId })?.name
        let link: BuddyLink
        if let existing = links.first(where: { $0.id == buddyId }) {
            link = existing
            if let discoveredName { link.name = discoveredName }
            guard link.status != .connected else {
                persistSelection()
                return
            }
            link.cancelReconnectTimer()
            if let peripheral = link.peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            resetLink(link)
        } else {
            link = BuddyLink(selection: BuddySelection(id: buddyId, name: discoveredName))
            links.append(link)
        }
        persistSelection()
        attemptReconnect(link)
    }

    /// Forget one Buddy: send an unpair command so it clears its NVS, then
    /// disconnect and drop it from the persisted selection. Other Buddies
    /// stay connected.
    func forget(buddyId: UUID) {
        guard let link = links.first(where: { $0.id == buddyId }) else { return }
        link.cancelReconnectTimer()
        link.cancelPairingTimers()
        link.writeQueue.removeAll(keepingCapacity: false)
        link.forgetting = true

        // Tell Buddy to clear its paired-host record before we drop the link.
        // Use .withResponse so we wait for the write ACK before disconnecting.
        if let peripheral = link.peripheral, let writeChar = link.writeChar,
           link.status == .connected || link.status == .pairing || link.status == .pairWaitingConfirm {
            let unpair = BuddyUnpairPayload(hostId: hostIdentifier)
            if writeChar.properties.contains(.write) {
                link.pendingResponseWrite = .unpair
                peripheral.writeValue(unpair.encode(), for: writeChar, type: .withResponse)
                Self.log.info("Sent unpair frame (withResponse), will disconnect on ACK")
            } else if writeChar.properties.contains(.writeWithoutResponse) {
                peripheral.writeValue(unpair.encode(), for: writeChar, type: .withoutResponse)
                Self.log.info("Sent unpair frame (withoutResponse), disconnecting without ACK")
                completeForget(link)
            } else {
                Self.log.error("Buddy write characteristic does not support unpair writes; disconnecting")
                completeForget(link)
            }
            return
        }
        completeForget(link)
    }

    private func completeForget(_ link: BuddyLink) {
        guard links.contains(where: { $0 === link }) else { return }
        if let peripheral = link.peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        link.cancelReconnectTimer()
        link.clearConnection()
        link.forgetting = false
        links.removeAll { $0 === link }
        persistSelection()
        refreshDirectedScan()
    }

    // MARK: - Public writes

    /// Write a single frame to every connected Buddy.
    func send(_ frame: MascotFramePayload) {
        send(frame.encode(), priority: .primary, legacySafe: true)
    }

    /// Write a workspace update frame to every connected Buddy.
    func sendWorkspace(_ workspace: BuddyWorkspacePayload) {
        send(workspace.encode(), priority: .normal)
    }

    /// Write a message preview frame to every connected Buddy.
    func sendMessagePreview(_ preview: BuddyMessagePreviewPayload) {
        send(preview.encode(), priority: .auxiliary)
    }

    /// Write model info frame to every connected Buddy.
    func sendModel(_ model: BuddyModelPayload) {
        send(model.encode(), priority: .normal)
    }

    /// Write session stats frame to every connected Buddy.
    func sendStats(_ stats: BuddyStatsPayload) {
        send(stats.encode(), priority: .normal)
    }

    /// Write subagent count frame to every connected Buddy.
    func sendSubagent(_ subagent: BuddySubagentPayload) {
        send(subagent.encode(), priority: .normal)
    }

    /// Write event frame to every connected Buddy.
    func sendEvent(_ event: BuddyEventPayload) {
        send(event.encode(), priority: .control)
    }

    /// Write time hint frame to every connected Buddy.
    func sendTimeHint(_ timeHint: BuddyTimeHintPayload) {
        send(timeHint.encode(), priority: .auxiliary)
    }

    /// Write tool history entry frame to every connected Buddy.
    func sendToolHistory(_ entry: BuddyToolHistoryPayload) {
        send(entry.encode(), priority: .auxiliary)
    }

    /// Clear every connected Buddy's tool history timeline.
    func sendToolHistoryClear() {
        send(BuddyToolHistoryClearPayload().encode(), priority: .normal)
    }

    /// Write Buddy screen brightness to every connected Buddy.
    func sendBrightness(percent: Double) {
        send(BuddyBrightnessPayload(percent: percent).encode(), priority: .control, legacySafe: true)
    }

    /// Write Buddy screen orientation to every connected Buddy.
    func sendScreenOrientation(_ orientation: BuddyScreenOrientation) {
        send(BuddyScreenOrientationPayload(orientation: orientation).encode(), priority: .control, legacySafe: true)
    }

    /// Queue `data` on every connected link. Firmware connected in legacy
    /// fallback mode only understands the mascot frame and screen config, so
    /// richer panels skip those links unless `legacySafe`.
    private func send(_ data: Data, priority: BuddyWritePriority, legacySafe: Bool = false) {
        for link in links where link.status == .connected && link.writeChar != nil {
            guard legacySafe || !link.usesLegacyPairingFallback else { continue }
            enqueueWrite(data, priority: priority, on: link)
        }
    }

    // MARK: - Internals

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private func recreateCentralAfterAuthorizationRecovery() {
        if let central {
            if central.isScanning { central.stopScan() }
            for link in links {
                if let peripheral = link.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            central.delegate = nil
        }
        links.forEach(resetLink)
        central = nil
        ensureCentral()
    }

    private static var bluetoothAuthorizationDescription: String {
        switch CBManager.authorization {
        case .allowedAlways: return "allowedAlways"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        @unknown default: return "unknown(\(CBManager.authorization.rawValue))"
        }
    }

    /// Return a link to "not connected, not scheduled" without touching the
    /// selection.
    private func resetLink(_ link: BuddyLink) {
        link.cancelReconnectTimer()
        link.clearConnection()
        link.reconnectAttempt = 0
        link.lastError = nil
        link.status = .searchingSelected
    }

    private func link(for peripheral: CBPeripheral) -> BuddyLink? {
        links.first { $0.id == peripheral.identifier }
    }

    private func persistSelection() {
        BuddySelectionStore.save(links.map(\.selection), to: defaults)
    }

    private func enqueueWrite(_ data: Data, priority: BuddyWritePriority, on link: BuddyLink) {
        let dropped = link.writeQueue.append(data, priority: priority)
        if dropped > 0 {
            Self.log.debug("Dropped \(dropped) low-priority queued Buddy BLE frames under write backpressure")
        }
        drainPendingWrites(on: link)
    }

    private func drainPendingWrites(on link: BuddyLink) {
        guard let peripheral = link.peripheral, let writeChar = link.writeChar, link.status == .connected else { return }
        while !link.writeQueue.isEmpty, peripheral.canSendWriteWithoutResponse {
            guard let frame = link.writeQueue.popNext() else { break }
            peripheral.writeValue(frame.data, for: writeChar, type: .withoutResponse)
        }
    }

    /// Queue a `0xD0` frame for one paired link; the write queue sends it
    /// ahead of everything else and never drops it.
    private func sendFingerprint(_ data: Data, on link: BuddyLink) {
        guard link.status == .connected, link.writeChar != nil else { return }
        enqueueWrite(data, priority: .control, on: link)
    }

    private func startFingerprintChannel(on link: BuddyLink) {
        link.fingerprint?.connectionDropped()
        let channel = BuddyFingerprintChannel(linkId: link.id, send: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.sendFingerprint(data, on: link)
        }, schedule: Self.fingerprintSchedule)
        link.fingerprint = channel
        channel.start()
    }

    private static let fingerprintSchedule: BuddyFingerprintSchedule = { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        return { timer.invalidate() }
    }

    private static let hostIdDefaultsKey = "buddyHostIdentifier"

    /// Load or generate a stable 6-byte host identifier persisted in UserDefaults.
    private static func loadOrCreateHostId() -> Data {
        let defaults = UserDefaults.standard
        if let existing = defaults.data(forKey: hostIdDefaultsKey),
           existing.count == ESP32Protocol.hostIdLength {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: ESP32Protocol.hostIdLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            let uuid = UUID()
            let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            bytes = Array(uuidBytes.prefix(ESP32Protocol.hostIdLength))
        }
        let data = Data(bytes)
        defaults.set(data, forKey: hostIdDefaultsKey)
        return data
    }

    /// Send a pair request frame using the raw write characteristic.
    /// Called before `.connected` is reached, so we bypass the `send()` guard.
    private func sendPairRequest(on link: BuddyLink) {
        guard let peripheral = link.peripheral, let writeChar = link.writeChar else { return }
        let payload = BuddyPairRequestPayload(hostId: hostIdentifier)
        let data = payload.encode()
        if writeChar.properties.contains(.write) {
            link.pendingResponseWrite = .pairRequest
            peripheral.writeValue(data, for: writeChar, type: .withResponse)
            Self.log.info("Pair request sent (withResponse)")
        } else if writeChar.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
            Self.log.info("Pair request sent (withoutResponse)")
            schedulePairResponseTimeout(on: link, allowsLegacyFallback: true)
        } else {
            Self.log.error("Buddy write characteristic does not support writes")
            link.lastError = "Buddy write characteristic does not support writes"
            link.status = .pairRejected
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func schedulePairResponseTimeout(on link: BuddyLink, allowsLegacyFallback: Bool) {
        link.pairResponseTimer?.invalidate()
        link.pairResponseAllowsLegacyFallback = allowsLegacyFallback
        link.pairResponseTimer = Timer.scheduledTimer(
            withTimeInterval: ESP32Protocol.pairResponseTimeoutSeconds,
            repeats: false
        ) { [weak self, weak link] _ in
            Task { @MainActor in
                guard let self, let link else { return }
                self.handlePairResponseTimeout(on: link)
            }
        }
    }

    private func schedulePairTimeout(on link: BuddyLink) {
        link.pairTimeoutTimer?.invalidate()
        link.pairTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(ESP32Protocol.pairConfirmTimeoutSeconds),
            repeats: false
        ) { [weak self, weak link] _ in
            Task { @MainActor in
                guard let self, let link else { return }
                self.handlePairTimeout(on: link)
            }
        }
    }

    private func handlePairTimeout(on link: BuddyLink) {
        guard link.status == .pairWaitingConfirm else { return }
        Self.log.error("Pair confirmation timed out after \(ESP32Protocol.pairConfirmTimeoutSeconds)s")
        link.pairTimeoutTimer = nil
        link.lastError = "Pairing was not completed. Press BOOT on Buddy to approve, or hold BOOT for 3s to reset pairing."
        link.status = .pairRejected
        if let peripheral = link.peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func handlePairResponseTimeout(on link: BuddyLink) {
        guard link.status == .pairing else { return }
        link.pairResponseTimer = nil
        if link.pairResponseAllowsLegacyFallback {
            Self.log.info("No pair response received after no-response write; continuing in legacy Buddy firmware compatibility mode")
            link.pairResponseAllowsLegacyFallback = false
            link.usesLegacyPairingFallback = true
            link.lastError = nil
            link.status = .connected
            onConnected?()
        } else {
            Self.log.error("No pair response received from Buddy after acknowledged pair request")
            link.pairResponseAllowsLegacyFallback = false
            link.usesLegacyPairingFallback = false
            link.lastError = "Buddy did not respond to pairing. Reconnect or flash the latest Buddy firmware."
            link.status = .pairRejected
            if let peripheral = link.peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    /// Reconnect every selected Buddy that has no connection in progress.
    private func reconnectIdleLinks() {
        for link in links where link.peripheral == nil && link.reconnectTimer == nil {
            attemptReconnect(link)
        }
    }

    /// Either retrieve the selected peripheral from the system cache and
    /// connect directly, or mark the link as searching so the directed scan
    /// connects once the matching identifier shows up.
    private func attemptReconnect(_ link: BuddyLink) {
        link.cancelReconnectTimer()
        guard started, let central, central.state == .poweredOn else {
            // CBCentralManagerDelegate.didUpdateState will retry once powered on.
            return
        }

        if let cachedPeripheral = central.retrievePeripherals(withIdentifiers: [link.id]).first {
            Self.log.info("Reconnecting to cached peripheral \(cachedPeripheral.name ?? "<unnamed>")")
            connect(cachedPeripheral, for: link)
            return
        }

        // No cached handle: scan and wait for the right identifier.
        link.status = .searchingSelected
        refreshDirectedScan()
    }

    private func connect(_ peripheral: CBPeripheral, for link: BuddyLink) {
        link.cancelReconnectTimer()
        link.peripheral = peripheral
        peripheral.delegate = self
        if let live = peripheral.name, !live.isEmpty, live != link.name {
            link.name = live
            persistSelection()
        }
        link.status = .connecting
        central?.connect(peripheral, options: nil)
    }

    /// Keep a directed scan running while any selected Buddy is waiting to be
    /// seen; the discovery scan already covers that while it runs.
    private func refreshDirectedScan() {
        guard let central, central.state == .poweredOn, !isDiscovering else { return }
        let needsScan = links.contains { $0.peripheral == nil && $0.status == .searchingSelected }
        if needsScan {
            guard !central.isScanning else { return }
            let serviceUUID = CBUUID(string: ESP32Protocol.serviceUUID)
            central.scanForPeripherals(withServices: [serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            Self.log.info("Directed scan for selected Buddies")
        } else if central.isScanning {
            central.stopScan()
        }
    }

    private func scheduleReconnect(_ link: BuddyLink) {
        link.cancelReconnectTimer()
        let idx = min(link.reconnectAttempt, Self.reconnectBackoff.count - 1)
        let delay = Self.reconnectBackoff[idx]
        link.reconnectAttempt += 1
        link.status = .reconnecting(delay)
        Self.log.info("Scheduling reconnect in \(delay)s (attempt \(link.reconnectAttempt))")
        link.reconnectTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self, weak link] _ in
            Task { @MainActor in
                guard let self, let link else { return }
                link.reconnectTimer = nil
                self.attemptReconnect(link)
            }
        }
    }

    private func stopDiscoveryInternal(resumeLinks: Bool) {
        isDiscovering = false
        discoveryPruneTimer?.invalidate()
        discoveryPruneTimer = nil
        guard let central else { return }
        if central.isScanning {
            central.stopScan()
        }
        if resumeLinks {
            refreshDirectedScan()
        }
    }

    private func startDiscoveryPruneTimer() {
        discoveryPruneTimer?.invalidate()
        discoveryPruneTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneStaleDiscoveries()
            }
        }
    }

    private func pruneStaleDiscoveries() {
        let cutoff = Date().addingTimeInterval(-Self.discoveryStaleSeconds)
        let connectedIds = Set(links.compactMap { $0.peripheral?.identifier })
        let filtered = discovered.filter { $0.lastSeen >= cutoff || connectedIds.contains($0.id) }
        if filtered.count != discovered.count {
            discovered = filtered
        }
    }

    fileprivate func updateDiscovery(peripheral: CBPeripheral, name: String?, rssi: Int) {
        // Only count peripherals whose names look like Buddies (or unnamed,
        // which can happen on first advertisement). Service-UUID scan filter
        // already restricts to our firmware.
        let resolvedName = name ?? peripheral.name ?? "Buddy"
        let now = Date()
        if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[idx].name = resolvedName
            discovered[idx].rssi = rssi
            discovered[idx].lastSeen = now
        } else {
            discovered.append(DiscoveredBuddy(
                id: peripheral.identifier,
                name: resolvedName,
                rssi: rssi,
                lastSeen: now
            ))
        }
        // Sort by RSSI descending (closer first); stable-ish ordering.
        discovered.sort { $0.rssi > $1.rssi }

        // If this is a selected Buddy without a connection, kick one off.
        // A rejected pairing waits for the user to pick it again.
        if started,
           let link = link(for: peripheral),
           link.peripheral == nil,
           link.status != .pairRejected {
            Self.log.info("Selected Buddy appeared in scan; connecting")
            if link.name != resolvedName {
                link.name = resolvedName
                persistSelection()
            }
            connect(peripheral, for: link)
            refreshDirectedScan()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ESP32BridgeManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central === self.central else { return }
            self.radioState = central.state
            switch central.state {
            case .poweredOn:
                self.authorizationRecoveryResetAttempted = false
                self.lastError = nil
                if self.isDiscovering {
                    self.startDiscovery()
                }
                self.reconnectIdleLinks()
                return
            case .poweredOff:
                self.lastError = "Bluetooth is off"
            case .unauthorized:
                let authorization = Self.bluetoothAuthorizationDescription
                let bundleId = Bundle.main.bundleIdentifier ?? "nil"
                let bundlePath = Bundle.main.bundlePath
                Self.log.error("Bluetooth unauthorized: authorization=\(authorization, privacy: .public) bundle=\(bundleId, privacy: .public) path=\(bundlePath, privacy: .public)")
                if CBManager.authorization == .allowedAlways,
                   !self.authorizationRecoveryResetAttempted {
                    self.authorizationRecoveryResetAttempted = true
                    Self.log.info("Bluetooth authorization is allowed again; recreating CBCentralManager")
                    self.radioState = .unknown
                    self.recreateCentralAfterAuthorizationRecovery()
                    return
                }
                self.lastError = "Bluetooth permission denied"
            case .unsupported:
                self.lastError = "Bluetooth unsupported on this Mac"
            case .resetting:
                self.lastError = "Bluetooth is resetting"
            case .unknown:
                break
            @unknown default:
                break
            }
            // Connections don't survive the radio going away; start the
            // links over once it is powered on again.
            self.links.forEach(self.resetLink)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssiInt = RSSI.intValue
        Task { @MainActor in
            self.updateDiscovery(peripheral: peripheral, name: advName, rssi: rssiInt)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let link = self.link(for: peripheral), link.peripheral === peripheral else {
                // Forgotten (or replaced) while the connect was in flight.
                central.cancelPeripheralConnection(peripheral)
                return
            }
            Self.log.info("Connected to \(link.displayName), discovering services")
            link.usesLegacyPairingFallback = false
            link.pendingResponseWrite = nil
            peripheral.discoverServices([CBUUID(string: ESP32Protocol.serviceUUID)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            Self.log.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
            guard let link = self.link(for: peripheral), link.peripheral === peripheral else { return }
            link.clearConnection()
            link.lastError = error?.localizedDescription
            if self.started {
                self.scheduleReconnect(link)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            Self.log.info("Disconnected: \(error?.localizedDescription ?? "peer closed")")
            guard let link = self.link(for: peripheral), link.peripheral === peripheral else { return }
            link.clearConnection()
            if link.forgetting {
                // Link dropped during forget flow (write ACK may never arrive).
                self.completeForget(link)
            } else if link.status == .pairRejected {
                // Don't auto-reconnect after rejection; user must act.
            } else if self.started {
                self.scheduleReconnect(link)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ESP32BridgeManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let link = self.link(for: peripheral) else { return }
            if let error {
                Self.log.error("discoverServices error: \(error.localizedDescription)")
                link.lastError = error.localizedDescription
                return
            }
            let target = CBUUID(string: ESP32Protocol.serviceUUID)
            guard let service = peripheral.services?.first(where: { $0.uuid == target }) else {
                Self.log.error("Target service missing from peripheral")
                link.lastError = "Service not found on device"
                return
            }
            peripheral.discoverCharacteristics([
                CBUUID(string: ESP32Protocol.writeCharacteristicUUID),
                CBUUID(string: ESP32Protocol.notifyCharacteristicUUID),
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard let link = self.link(for: peripheral) else { return }
            if let error {
                Self.log.error("discoverCharacteristics error: \(error.localizedDescription)")
                link.lastError = error.localizedDescription
                return
            }
            let writeUUID = CBUUID(string: ESP32Protocol.writeCharacteristicUUID)
            let notifyUUID = CBUUID(string: ESP32Protocol.notifyCharacteristicUUID)
            for ch in service.characteristics ?? [] {
                if ch.uuid == writeUUID {
                    link.writeChar = ch
                } else if ch.uuid == notifyUUID {
                    guard ch.properties.contains(.notify) || ch.properties.contains(.indicate) else {
                        Self.log.error("Buddy uplink characteristic missing notify/indicate property")
                        link.lastError = "Buddy uplink characteristic is not subscribable"
                        return
                    }
                    link.notifyChar = ch
                    link.notifySubscriptionReady = false
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
            guard link.writeChar != nil, link.notifyChar != nil else {
                Self.log.error("Missing write or notify characteristic")
                link.lastError = "Device missing expected characteristics"
                return
            }
            Self.log.info("Buddy characteristics discovered; waiting for uplink subscription")
            link.lastError = nil
            link.status = .connecting
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == CBUUID(string: ESP32Protocol.notifyCharacteristicUUID),
                  let link = self.link(for: peripheral) else {
                return
            }
            if let error {
                Self.log.error("didUpdateNotificationState error: \(error.localizedDescription)")
                link.lastError = error.localizedDescription
                link.notifySubscriptionReady = false
                return
            }
            guard characteristic.isNotifying else {
                Self.log.error("Buddy uplink subscription is not active")
                link.lastError = "Buddy uplink subscription is not active"
                link.notifySubscriptionReady = false
                return
            }
            guard !link.notifySubscriptionReady else { return }

            Self.log.info("Buddy uplink subscription enabled — initiating pair handshake")
            link.notifySubscriptionReady = true
            link.reconnectAttempt = 0
            link.lastError = nil
            if let live = peripheral.name, !live.isEmpty, live != link.name {
                link.name = live
                self.persistSelection()
            }
            link.status = .pairing
            self.sendPairRequest(on: link)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == CBUUID(string: ESP32Protocol.writeCharacteristicUUID),
                  let link = self.link(for: peripheral) else {
                return
            }
            guard let pending = link.pendingResponseWrite else {
                if link.forgetting {
                    if let error {
                        Self.log.error("Unpair write ACK error (proceeding anyway): \(error.localizedDescription)")
                    }
                    self.completeForget(link)
                }
                return
            }
            link.pendingResponseWrite = nil
            switch pending {
            case .pairRequest:
                if let error {
                    Self.log.error("Pair request write ACK error: \(error.localizedDescription)")
                    link.cancelPairingTimers()
                    link.lastError = "Pair request could not be delivered: \(error.localizedDescription)"
                    link.usesLegacyPairingFallback = false
                    link.status = .pairRejected
                    self.central?.cancelPeripheralConnection(peripheral)
                    return
                }
                Self.log.info("Pair request write ACK received; waiting for Buddy pair response")
                if link.status == .pairing {
                    self.schedulePairResponseTimeout(on: link, allowsLegacyFallback: false)
                }
            case .unpair:
                if let error {
                    Self.log.error("Unpair write ACK error (proceeding anyway): \(error.localizedDescription)")
                }
                self.completeForget(link)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let link = self.link(for: peripheral), link.peripheral === peripheral else { return }
            self.drainPendingWrites(on: link)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                Self.log.error("didUpdateValue error: \(error.localizedDescription)")
                return
            }
            guard characteristic.uuid == CBUUID(string: ESP32Protocol.notifyCharacteristicUUID),
                  let link = self.link(for: peripheral),
                  let data = characteristic.value,
                  let event = BuddyUplinkEvent(payload: data) else {
                return
            }
            switch event {
            case .pairResponse(let response):
                self.handlePairResponse(response, on: link)
            case .focus(let mascot):
                Self.log.info("Button event from \(link.displayName): mascot=\(mascot.sourceName)")
                self.onFocusRequest?(mascot)
            case .command(let command):
                Self.log.info("Buddy control event from \(link.displayName): command=\(String(describing: command)) raw=\(command.rawValue)")
                self.onControlCommand?(command)
            case .fingerprint(let frame):
                link.fingerprint?.handle(frame)
            }
        }
    }

    @MainActor
    private func handlePairResponse(_ response: BuddyPairResponse, on link: BuddyLink) {
        link.cancelPairResponseTimeout()
        switch response {
        case .accepted:
            Self.log.info("Pair accepted by \(link.displayName)")
            link.cancelPairTimeout()
            link.lastError = nil
            link.usesLegacyPairingFallback = false
            link.status = .connected
            startFingerprintChannel(on: link)
            onConnected?()
        case .rejected:
            Self.log.error("Pair rejected or not completed by \(link.displayName)")
            link.cancelPairTimeout()
            link.lastError = "Pairing was not completed. If Buddy is paired with another Mac, hold BOOT for 3s on Buddy to reset pairing."
            link.usesLegacyPairingFallback = false
            link.status = .pairRejected
            if let peripheral = link.peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
        case .pending:
            Self.log.info("Pair pending — waiting for user confirmation on \(link.displayName)")
            link.lastError = nil
            link.usesLegacyPairingFallback = false
            link.status = .pairWaitingConfirm
            schedulePairTimeout(on: link)
        }
    }
}
