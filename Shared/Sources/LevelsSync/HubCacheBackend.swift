import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import os

/// The Mac hub's ``HubBackend`` (NET-001 Design `MacHubBackend`): serves the App Group
/// ``SnapshotCache``, ingests client readings through ``LocalOnlySyncService``, and runs the
/// pairing steps through ``PairingWindow`` and the ``HubPairingStore``. Lives in LevelsSync
/// (not the Mac target) so the loopback tests run it with `swift test`.
public final class HubCacheBackend: HubBackend {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let local: LocalOnlySyncService
    private let cache: SnapshotCache
    private let reporting: ReportingSetting
    private let store: any HubPairingStore
    private let window: PairingWindow
    private let signal: HubChangeSignal
    private let hub: @Sendable () -> HubInfo?
    private let now: @Sendable () -> Date
    private let onChange: @Sendable () -> Void
    private let onSeen: @Sendable (DeviceID) -> Void
    private let onPairingsChanged: @Sendable () -> Void
    /// This Mac's push public key (PUSH-001 R18); `nil` = push off: `GET /v1/push-key` is 404.
    private let pushKey: (@Sendable () -> String?)?
    private let listener = Mutex<HubListener?>(nil)
    /// The last snapshot read, served when the cache file can't be read (NET-001 edge case).
    private let lastGood = Mutex<HubSnapshot?>(nil)

    /// - Parameters:
    ///   - hub: the hub ID, the Mac's device ID and display name; `nil` until the device ID exists.
    ///   - signal: fired by the app whenever its cache changes (reports, ingests, removes).
    ///   - onChange: called after an ingest or remove changed the cache (the app fires its
    ///     change relay, which also fires `signal`).
    ///   - onSeen: called after each authenticated device request (firewall hint, NET-001 R15).
    ///   - onPairingsChanged: called after a device forgot this Mac (`DELETE /v1/pairing`), so
    ///     the app re-applies its listener rule (NET-001 R1) and refreshes its paired list.
    public init(local: LocalOnlySyncService, cache: SnapshotCache, reporting: ReportingSetting,
                store: any HubPairingStore, window: PairingWindow, signal: HubChangeSignal,
                hub: @escaping @Sendable () -> HubInfo?, now: @escaping @Sendable () -> Date = Date.init,
                onChange: @escaping @Sendable () -> Void = {}, onSeen: @escaping @Sendable (DeviceID) -> Void = { _ in },
                onPairingsChanged: @escaping @Sendable () -> Void = {}, pushKey: (@Sendable () -> String?)? = nil) {
        self.onPairingsChanged = onPairingsChanged
        self.pushKey = pushKey
        self.local = local
        self.cache = cache
        self.reporting = reporting
        self.store = store
        self.window = window
        self.signal = signal
        self.hub = hub
        self.now = now
        self.onChange = onChange
        self.onSeen = onSeen
    }

    /// The listener whose keys change on pairing (late-bound: the listener needs the router,
    /// which needs this backend).
    public func attach(_ listener: HubListener) { self.listener.withLock { $0 = listener } }

    private var attached: HubListener? { listener.withLock { $0 } }

    public func snapshot() async -> HubSnapshot? {
        guard reporting.isEnabled, let hub = hub() else { return nil }
        let cache = cache
        guard let file = await Task.detached(priority: .utility, operation: { cache.read() }).value else {
            return lastGood.withLock { $0 }
        }
        let snapshot = HubSnapshot(hubID: hub.hubID, hubDeviceID: hub.hubDeviceID, generatedAt: now(), devices: file.devices)
        lastGood.withLock { $0 = snapshot }
        return snapshot
    }

    public func changes() -> AsyncStream<Void> { signal.stream() }

    public func ingest(_ record: DeviceBattery) async -> Bool {
        guard reporting.isEnabled else { return false }
        if await local.ingest([record], replacingAllExcept: nil) {
            onChange()
            signal.fire()
        }
        return true
    }

    public func setPushUpload(_ upload: PushTokenUpload, for id: DeviceID) async -> PushUploadResult {
        guard store.key(for: id) != nil else { return .failed }  // a pending pairing has no item yet
        // A grant must name this Mac's key and cover every token, or the relay would refuse every
        // push. Unverified read: only the relay can check its MAC.
        if let grant = upload.grant, !upload.tokens.isEmpty {
            guard let macKey = pushKey?(), PushGrantInfo.read(grant)?.covers(upload.tokens, macKey: macKey) == true else {
                Self.logger.notice("Push grant from \(id.recordName, privacy: .public) doesn't match this Mac or its tokens")
                return .rejected
            }
        }
        do {
            guard try store.setPushRegistration(upload.tokens, grant: upload.grant, expiresAt: upload.grantExpiresAt, for: id) else {
                return .failed
            }
            Self.logger.notice("Push tokens for \(id.recordName, privacy: .public): \(upload.tokens.count, privacy: .public), grant \(upload.grant == nil ? "none" : "yes", privacy: .public)")
            return .stored
        } catch {
            Self.logger.error("Push tokens for \(id.recordName, privacy: .public): Keychain write failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    public func pushKey(for id: DeviceID) async -> PushKeyAnswer? {
        guard let macKey = pushKey?() else { return nil }
        let client = store.all().first { $0.id == id }
        return PushKeyAnswer(macKey: macKey, grant: Self.grantState(client, macKey: macKey, now: now()))
    }

    /// Pure; unit-tested.
    static func grantState(_ client: PairedClient?, macKey: String, now: Date) -> PushKeyAnswer.GrantState {
        guard let client, let grant = client.pushGrant else { return .none }
        if client.pushNeedsGrant == true { return .renew }
        guard let info = PushGrantInfo.read(grant), info.covers(client.pushTokens ?? [], macKey: macKey) else { return .renew }
        let expiry = client.pushGrantExpiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? info.expiresAt
        return expiry.timeIntervalSince(now) < HubProtocol.pushGrantRenewBefore ? .renew : .ok
    }

    public func removeRecord(_ id: DeviceID) async {
        await local.removeLocal(id)
        onChange()
        signal.fire()
    }

    public func forget(_ id: DeviceID) async {
        do { try store.remove(id) } catch {
            Self.logger.error("Forget \(id.recordName, privacy: .public): Keychain delete failed: \(String(describing: error), privacy: .public)")
        }
        Self.logger.notice("Forgot device \(id.recordName, privacy: .public)")
        await attached?.reload()
        // The app decides whether the listener should still run (no devices left → stop
        // advertising) and refreshes its paired list.
        onPairingsChanged()
    }

    public func isPaired(_ id: DeviceID) -> Bool { store.key(for: id) != nil || window.pendingID == id }

    public func pair(_ request: PairRequest) async throws(PairError) -> PairResponse {
        let response = try window.accept(request)
        Self.logger.notice("Pairing request from \(request.deviceID.recordName, privacy: .public); waiting for its key")
        return response
    }

    public func confirmPairing(_ request: PairConfirmRequest) async throws(PairError) {
        try window.reveal(request)
        // The `pair` key is gone now; no new pairing handshakes.
        await attached?.reload()
        Self.logger.notice("Pairing: waiting for the owner to compare the numbers")
        switch await window.decision() {
        case .matched:
            // The confirming request (R7) uses the new key, so the listener must hold it first;
            // a 204 without it would send the device into a handshake that can't succeed.
            guard let listener = attached, await listener.reload() else {
                Self.logger.error("Pairing: listener could not load the new key")
                throw .notReachable
            }
            Self.logger.notice("Pairing: numbers match; waiting for the device's first request")
        case .cancelled:
            Self.logger.notice("Pairing cancelled on the Mac")
            throw .refused
        case .expired:
            Self.logger.notice("Pairing window ended before the numbers were compared")
            throw .timedOut
        }
    }

    public func seen(_ id: DeviceID) async {
        if window.pendingID == id, window.confirm(id) != nil {
            Self.logger.notice("Pairing confirmed for \(id.recordName, privacy: .public)")
            await attached?.reload()
        }
        store.touch(id, at: now())
        onSeen(id)
    }
}
