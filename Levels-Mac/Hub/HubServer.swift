// NET-001 + NET-002 (Mac side): the local-network hub (ADR-0020, owner decision M).
// Owns the listener, the pairing window and the paired-device store, and applies the
// listener rule of NET-001 R1 / lead's call 25.
import Foundation
import LevelsModel
import LevelsNet
import LevelsSync
import Observation
import os

@MainActor @Observable final class HubServer {
    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    enum Status: Equatable {
        /// "Share with iPhone" is off.
        case off
        /// Reporting is off (Remove all my data, NET-001 R13).
        case reportingOff
        /// No device paired and no pairing window (R1).
        case notPaired
        case starting
        case sharing
        /// The listener failed twice (edge case: retry once after 5 s, then this).
        case failed
    }

    private(set) var status: Status = .notPaired
    private(set) var paired: [PairedClient] = []
    private(set) var pairingState: PairingWindow.State = .closed
    private(set) var tag: String
    /// NET-001 R15: last successful handshake, persisted.
    private(set) var lastHandshakeAt: Date?

    /// NET-001 R1, R14: "Share with iPhone on this Wi-Fi", default on.
    var sharingEnabled: Bool {
        didSet {
            defaults.set(sharingEnabled, forKey: Self.sharingKey)
            Self.logger.notice("Share with iPhone \(self.sharingEnabled ? "on" : "off", privacy: .public)")
            Task { await evaluate() }
        }
    }

    static let hubIDKey = "net.hubID"
    static let sharingKey = "net.sharing"
    static let lastHandshakeKey = "net.lastHandshakeAt"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reporting: ReportingSetting
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private let hubName: @Sendable () -> String
    @ObservationIgnored let store: any HubPairingStore
    @ObservationIgnored let window: PairingWindow
    @ObservationIgnored private let listener: HubListener
    @ObservationIgnored private let hubIDBox: HubIDBox
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var evaluating = false
    @ObservationIgnored private var evaluateAgain = false

    init(local: LocalOnlySyncService, cache: SnapshotCache, reporting: ReportingSetting, defaults: UserDefaults,
         identity: any DeviceIdentityProviding, signal: HubChangeSignal, onChange: @escaping @Sendable () -> Void,
         hubName: @escaping @Sendable () -> String) {
        self.defaults = defaults
        self.reporting = reporting
        self.identity = identity
        self.hubName = hubName
        sharingEnabled = defaults.object(forKey: Self.sharingKey) as? Bool ?? true
        lastHandshakeAt = defaults.object(forKey: Self.lastHandshakeKey) as? Date

        let hubIDBox = HubIDBox(Self.loadHubID(defaults))  // R3
        self.hubIDBox = hubIDBox
        tag = HubProtocol.tag(for: hubIDBox.value)

        let service = LevelsAppConfig.keychainService.replacingOccurrences(of: ".device-identity", with: "") + ".hub.client"
        let store = KeychainHubPairingStore(service: service, items: SecKeychainItems(accessGroup: LevelsAppConfig.keychainAccessGroup))
        let window = PairingWindow(store: store)
        self.store = store
        self.window = window

        let hubInfo: @Sendable () -> HubInfo? = {
            guard let id = try? identity.currentDeviceID() else { return nil }
            return HubInfo(hubID: hubIDBox.value, hubDeviceID: id, hubName: hubName())
        }
        let backend = HubCacheBackend(local: local, cache: cache, reporting: reporting, store: store, window: window,
                                      signal: signal, hub: hubInfo, onChange: onChange)
        let events = EventRelay()
        listener = HubListener(router: HubRouter(backend: backend), keyring: HubKeyring(store: store, window: window),
                               advertise: {
                                   HubListener.Advertisement(tag: HubProtocol.tag(for: hubIDBox.value), pairing: window.isOpen)
                               },
                               events: { events.send($0) })
        backend.attach(listener)
        paired = store.all()
        events.set { [weak self] event in Task { @MainActor in self?.handle(event) } }
        window.setObserver { [weak self] in Task { @MainActor in await self?.windowChanged() } }
    }

    private static func loadHubID(_ defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: hubIDKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: hubIDKey)
        return id
    }

    // MARK: R1

    /// Starts, reloads or stops the listener so it runs only while reporting is on,
    /// sharing is on, and a device is paired or the window is open.
    func evaluate() async {
        if evaluating { evaluateAgain = true; return }
        evaluating = true
        defer { evaluating = false }
        repeat {
            evaluateAgain = false
            await applyRule()
        } while evaluateAgain
    }

    private func applyRule() async {
        paired = store.all()
        let shouldRun = reporting.isEnabled && sharingEnabled && (!paired.isEmpty || window.isOpen)
        let running = await listener.isRunning
        if shouldRun {
            if running {
                await listener.reload()
                status = .sharing
            } else if status != .failed || window.isOpen {
                await startListener()
            }
        } else {
            if running {
                await listener.stop()
                Self.logger.notice("Hub listener stopped")
            }
            status = !reporting.isEnabled ? .reportingOff : !sharingEnabled ? .off : .notPaired
            if status == .notPaired { Self.logger.notice("Hub: no device paired; listener not running") }
        }
    }

    private func startListener() async {
        status = .starting
        do {
            let port = try await listener.start()
            retried = false
            status = .sharing
            Self.logger.notice("Hub sharing as \(HubProtocol.serviceName(tag: self.tag), privacy: .public) on port \(port, privacy: .public)")
        } catch {
            Self.logger.error("Hub listener start failed: \(String(describing: error), privacy: .public)")
            await failedOnce()
        }
    }

    /// Edge case: retry once after 5 s; then "Couldn't start sharing" with Retry. No loop.
    private func failedOnce() async {
        guard !retried else {
            status = .failed
            return
        }
        retried = true
        status = .starting
        try? await Task.sleep(for: .seconds(5))
        await startListener()
    }

    /// The Retry button.
    func retry() {
        retried = false
        status = .starting
        Task { await startListener() }
    }

    private func handle(_ event: HubListener.Event) {
        switch event {
        case .handshakeSucceeded(.device):
            let now = Date()
            // R15; written at most once a minute.
            if lastHandshakeAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                lastHandshakeAt = now
                defaults.set(now, forKey: Self.lastHandshakeKey)
                paired = store.all()
            }
        case .failed:
            Task { await failedOnce() }
        default: break
        }
    }

    // MARK: Pairing (NET-002)

    /// Opens the pairing window (R1). `nil` when this Mac's device ID isn't readable yet.
    @discardableResult
    func openPairing() -> String? {
        guard let id = try? identity.currentDeviceID() else {
            Self.logger.error("Pairing: device ID unavailable")
            return nil
        }
        retried = false
        if status == .failed { status = .starting }
        let code = window.open(hub: HubInfo(hubID: hubIDBox.value, hubDeviceID: id, hubName: hubName()))
        Self.logger.notice("Pairing window opened for \(HubProtocol.serviceName(tag: self.tag), privacy: .public)")
        return code
    }

    func closePairing() {
        window.close()
    }

    private func windowChanged() async {
        pairingState = window.state
        expiryTask?.cancel()
        if case .open(_, let endsAt, _) = pairingState {
            // One-shot wait tied to the window (R17): ends it on time even with the sheet idle.
            let window = window
            expiryTask = Task {
                try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow) + 0.1))
                guard !Task.isCancelled else { return }
                window.expireIfDue()
            }
        }
        if case .paired = pairingState { Self.logger.notice("Pairing confirmed") }
        await evaluate()
    }

    /// NET-002 R9: deletes the key, closes the device's connections, keeps its cache record.
    func remove(_ id: DeviceID) async {
        do { try store.remove(id) } catch {
            Self.logger.error("Remove \(id.recordName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        Self.logger.notice("Removed paired device \(id.recordName, privacy: .public)")
        await listener.closeConnections(of: id)
        await evaluate()
    }

    /// NET-001 R14: drops every key and makes a new hub ID (and tag).
    func removeAllPairings() async {
        let ids = store.all().map(\.id)
        do { try store.removeAll() } catch {
            Self.logger.error("Remove all pairings failed: \(String(describing: error), privacy: .public)")
        }
        let newID = UUID()
        defaults.set(newID.uuidString, forKey: Self.hubIDKey)
        hubIDBox.value = newID
        tag = HubProtocol.tag(for: newID)
        lastHandshakeAt = nil
        defaults.removeObject(forKey: Self.lastHandshakeKey)
        for id in ids { await listener.closeConnections(of: id) }
        Self.logger.notice("Removed all pairings; new hub tag \(self.tag, privacy: .public)")
        await evaluate()
    }

    /// NET-001 R15: running, a device paired, and no handshake for 24 h.
    func showsFirewallHint(now: Date = Date()) -> Bool {
        guard status == .sharing, let firstPaired = paired.map(\.pairedAt).min() else { return false }
        let since = max(lastHandshakeAt ?? firstPaired, firstPaired)
        return now.timeIntervalSince(since) > 24 * 3600
    }
}

/// The hub ID, replaced by "Remove all pairings"; read by the listener's callbacks.
final class HubIDBox: Sendable {
    private let lock = OSAllocatedUnfairLock<UUID>(initialState: UUID())
    init(_ id: UUID) { lock.withLock { $0 = id } }
    var value: UUID {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Late-bound listener events: the listener is built before `self` can be captured.
final class EventRelay: Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (HubListener.Event) -> Void)?>(initialState: nil)
    func set(_ h: @escaping @Sendable (HubListener.Event) -> Void) { handler.withLock { $0 = h } }
    func send(_ e: HubListener.Event) { handler.withLock { $0 }?(e) }
}
