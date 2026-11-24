import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import os

/// The one outbox slot of NET-003 R2: the latest own reading that reached the cache and has
/// not been accepted by the Mac yet. Latest wins. Filled by ``LocalOnlySyncService``'s
/// `onOwnWrite` (direct writes and held flushes alike).
public final class HubOutbox: Sendable {
    private let slot = Mutex<DeviceBattery?>(nil)
    public init() {}
    public var value: DeviceBattery? { slot.withLock { $0 } }
    public func put(_ reading: DeviceBattery) { slot.withLock { $0 = reading } }
    /// R4: clears the slot only if it still holds `reading` (a newer one may have arrived).
    public func clear(ifStill reading: DeviceBattery) { slot.withLock { if $0 == reading { $0 = nil } } }
    public func clear() { slot.withLock { $0 = nil } }
}

/// The iPhone's sync in hub mode (NET-003, ADR-0020; lead's calls 22, 24): wraps
/// ``LocalOnlySyncService`` (own cache writes, ADR-0008 throttling, widget reloads), sends this
/// iPhone's own reading to the paired Mac, fetches the Mac's snapshot with an ETag, runs the
/// foreground long-poll, and records `.notPaired` / `.awayFromHub` and the other R9 states
/// in the App Group cache so the app and widgets show them.
///
/// Builder's calls kept from the spec's Design: the `HubClient` is built here from the
/// transport and the device identity (the device ID may be unreadable before first unlock),
/// and the outbox is a shared ``HubOutbox`` the inner service fills.
public actor LocalNetworkSyncService: BatterySyncing {
    /// R2: a report never waits longer than this for the send.
    public static let sendLimit: Duration = .seconds(5)
    /// R7: `GET /v1/snapshot?wait=25`.
    public static let liveWait: Duration = .seconds(25)
    /// R7: waits after a failed long-poll: 5 s, 15 s, then 60 s (cap).
    public static let liveBackoff: [Duration] = [.seconds(5), .seconds(15), .seconds(60)]
    /// NET-003 Design: the ETag is kept in memory and in App Group `UserDefaults`.
    public static let etagKey = "net.etag"

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let local: LocalOnlySyncService
    private let outbox: HubOutbox
    private let transport: any HubTransport
    private let pairing: any ClientPairingStore
    private let identity: any DeviceIdentityProviding
    private let cache: SnapshotCache
    private let etagSuite: String?
    private let persistsETag: Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onChange: @Sendable () -> Void

    private var client: HubClient?
    private var etag: String?
    private var lastFetchAt: Date?
    private var currentStatus: SyncStatus = .localOnly
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0
    private var statusContinuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    /// - Parameters:
    ///   - local: the inner service; build it with `onOwnWrite: { outbox.put($0) }`.
    ///   - transport: ``NWHubTransport`` in the app; a loopback or fake one in tests.
    ///   - etagSuite: the `UserDefaults` suite for `net.etag`; `persistsETag: false` keeps it in memory only.
    ///   - onChange: called when the cache's devices or status changed (the UI reloads).
    public init<C: Clock<Duration>>(local: LocalOnlySyncService, outbox: HubOutbox, transport: any HubTransport,
                                    pairing: any ClientPairingStore, identity: any DeviceIdentityProviding,
                                    cache: SnapshotCache, etagSuite: String? = nil, persistsETag: Bool = true,
                                    now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock(),
                                    onChange: @escaping @Sendable () -> Void = {}) {
        self.local = local
        self.outbox = outbox
        self.transport = transport
        self.pairing = pairing
        self.identity = identity
        self.cache = cache
        self.etagSuite = etagSuite
        self.persistsETag = persistsETag
        self.now = now
        self.sleep = { try await clock.sleep(for: $0) }
        self.onChange = onChange
        if persistsETag {
            etag = UserDefaults(suiteName: etagSuite)?.string(forKey: Self.etagKey)
        }
    }

    // MARK: BatterySyncing

    /// R9.
    public var status: SyncStatus { currentStatus }

    /// Whether a Mac pairing is stored.
    public var isPaired: Bool { pairing.current() != nil }

    /// The stored pairing (Settings ▸ Mac, NET-004 R7).
    public var currentPairing: HubPairing? { pairing.current() }

    /// The last good contact with the Mac (`SnapshotFile.lastFetchAt`).
    public var lastContactAt: Date? { lastFetchAt }

    /// R2: the inner service writes first; the outbox is then sent if the Mac is paired. The
    /// send never holds the report for more than ``sendLimit``.
    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        let outcome = await local.report(readings, reason: reason)
        if outbox.value != nil, isPaired {
            await Self.runLimited(Self.sendLimit, sleep: sleep) { await self.sendOutbox() }
        }
        return outcome
    }

    /// R3, R5, R9: sends the outbox, then fetches the snapshot with the last ETag.
    @discardableResult
    public func refresh(_ reason: RefreshReason) async -> Bool {
        guard let client = clientIfReady() else {
            if !isPaired { await setStatus(.notPaired) }
            return await cacheReadable()
        }
        if outbox.value != nil, let error = await sendOutbox(), Self.isUnreachable(error) {
            return await cacheReadable()
        }
        do {
            let fetch = try await client.snapshot(ifNoneMatch: etag, wait: nil)
            await handle(fetch)
        } catch {
            await apply(error)
        }
        return await cacheReadable()
    }

    /// Fires a held widget reload now (``LocalOnlySyncService/flushWidgetReload()``).
    public func flushWidgetReload() async { await local.flushWidgetReload() }

    // MARK: Lifecycle

    /// Launch: reads `lastFetchAt` from the cache and records the starting status
    /// (`.notPaired` when no pairing is stored). Replaces ``LocalOnlySyncService/start()``.
    public func start() async {
        let cache = cache
        let file = await Task.detached(priority: .utility) { cache.read() }.value
        lastFetchAt = file?.lastFetchAt
        // A cache that holds nothing from the Mac must not be answered with 304.
        if file?.devices.contains(where: { $0.id != file?.ownDeviceID }) != true { setETag(nil) }
        if !isPaired {
            await setStatus(.notPaired)
        } else {
            let cached = file?.syncStatus
            await setStatus(cached == nil || cached == .notPaired ? .localOnly : cached!)
        }
    }

    /// R7: one long-poll loop while the scene is active and the iPhone is paired.
    public func startLiveUpdates() {
        guard liveTask == nil, isPaired else { return }
        liveGeneration += 1
        let generation = liveGeneration
        liveTask = Task { await self.liveLoop(generation: generation) }
        Self.logger.notice("Live updates started")
    }

    /// R7: cancels the loop and drops the kept-alive connection (no background connection).
    public func stopLiveUpdates() async {
        guard let task = liveTask else { return }
        liveTask = nil
        liveGeneration += 1
        task.cancel()
        if let nw = transport as? NWHubTransport { await nw.reset() }
        Self.logger.notice("Live updates stopped")
    }

    /// Updates for the UI (NET-003 Design `statusUpdates()`); yields the current status first.
    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.yield(currentStatus)
        continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(id) } }
        return stream
    }

    // MARK: Pairing (NET-002 R7, R9)

    /// After the UI saved a new pairing: drop the old connection and ETag, then fetch.
    public func didPair() async {
        await stopLiveUpdates()
        if let nw = transport as? NWHubTransport { await nw.reset() }
        setETag(nil)
        await refresh(.userPull)
    }

    /// NET-002 R9 "Forget this Mac": `DELETE /v1/pairing` (best effort), delete the item,
    /// status `.notPaired`. Records from the Mac stay in the cache.
    public func forget() async {
        await stopLiveUpdates()
        if let client = clientIfReady() {
            await client.forget()
        } else {
            do { try pairing.remove() } catch {
                Self.logger.error("Forget: Keychain delete failed: \(String(describing: error), privacy: .public)")
            }
        }
        outbox.clear()
        setETag(nil)
        await setStatus(.notPaired)
    }

    // MARK: Remove all my data (R10, lead's call 28)

    /// Paired: `DELETE /v1/devices/me` first; only after `204` the local reset. Not
    /// reachable: throws the ``HubError`` and nothing changes. Not paired: local reset only.
    public func removeAllData() async throws {
        if isPaired {
            guard let client = clientIfReady() else { throw HubError.notPaired }
            do {
                try await client.deleteMe()
            } catch {
                Self.logger.notice("Remove all data: Mac not reachable (\(String(describing: error), privacy: .public))")
                throw error
            }
        }
        try await local.removeAllData()
        outbox.clear()
        setETag(nil)
        onChange()
    }

    /// R10: reporting on again; the status is written back to the cache.
    public func resumeReporting() async {
        await local.resumeReporting()
        await local.setStatus(currentStatus, lastFetchAt: lastFetchAt)
    }

    // MARK: Internals

    private func clientIfReady() -> HubClient? {
        guard isPaired else { return nil }
        if let client { return client }
        let me: DeviceID?
        do { me = try identity.currentDeviceID() } catch {
            Self.logger.error("Device ID unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let me else { return nil }
        let made = HubClient(transport: transport, pairing: pairing, me: me)
        client = made
        return made
    }

    /// R4. Returns the error when the send failed (the slot is kept), `nil` otherwise.
    @discardableResult
    private func sendOutbox() async -> HubError? {
        guard let record = outbox.value, let client = clientIfReady() else { return nil }
        do {
            try await client.post(record)
            outbox.clear(ifStill: record)
            if Self.isUnreachableStatus(currentStatus) { await setStatus(.localOnly) }
            return nil
        } catch .badResponse(403) {
            Self.logger.fault("POST /v1/readings refused (403) for \(record.id.recordName, privacy: .public); dropped")
            outbox.clear(ifStill: record)
            return nil
        } catch {
            await apply(error)
            return error
        }
    }

    private func handle(_ fetch: HubFetch) async {
        let t = now()
        var changed = false
        switch fetch {
        case .changed(let snapshot, let tag):
            let me = (try? identity.currentDeviceID()).flatMap { $0 }
            changed = await local.ingest(snapshot.devices, replacingAllExcept: Set([me].compactMap { $0 }))
            setETag(tag)
        case .notModified(let tag):
            if !tag.isEmpty { setETag(tag) }
        }
        lastFetchAt = t
        await setStatus(.localOnly, lastFetchAt: t)
        if changed { onChange() }
    }

    /// R9 table.
    private func apply(_ error: HubError) async {
        let status: SyncStatus
        switch error {
        case .notPaired: status = .notPaired
        case .notFound, .notReady, .timedOut: status = .awayFromHub(lastContactAt: lastFetchAt)
        case .handshakeRefused: status = .misconfigured(code: 401)
        case .localNetworkDenied: status = .restricted
        case .versionMismatch: status = .misconfigured(code: 426)
        case .badResponse(let code) where code == 401 || code == 426: status = .misconfigured(code: code)
        case .badResponse(let code):
            Self.logger.error("Hub answered \(code, privacy: .public); status kept")
            return
        }
        await setStatus(status)
    }

    private func setStatus(_ status: SyncStatus, lastFetchAt: Date? = nil) async {
        let changed = status != currentStatus
        if changed {
            Self.logger.notice("Hub status \(String(describing: status), privacy: .public)")
        }
        currentStatus = status
        await local.setStatus(status, lastFetchAt: lastFetchAt)
        if changed {
            for c in statusContinuations.values { c.yield(status) }
            onChange()
        }
    }

    private func setETag(_ tag: String?) {
        etag = tag
        guard persistsETag, let defaults = UserDefaults(suiteName: etagSuite) else { return }
        if let tag { defaults.set(tag, forKey: Self.etagKey) } else { defaults.removeObject(forKey: Self.etagKey) }
    }

    private func dropContinuation(_ id: UUID) { statusContinuations[id] = nil }

    private func cacheReadable() async -> Bool {
        let cache = cache
        return await Task.detached(priority: .utility) { cache.read() != nil }.value
    }

    private func liveLoop(generation: Int) async {
        var failures = 0
        while !Task.isCancelled, generation == liveGeneration {
            guard let client = clientIfReady() else { return }
            if outbox.value != nil { await sendOutbox() }
            do {
                let fetch = try await client.snapshot(ifNoneMatch: etag, wait: Self.liveWait)
                guard !Task.isCancelled, generation == liveGeneration else { return }
                await handle(fetch)
                failures = 0
            } catch {
                guard !Task.isCancelled, generation == liveGeneration else { return }
                await apply(error)
                let wait = Self.liveBackoff[min(failures, Self.liveBackoff.count - 1)]
                failures += 1
                do { try await sleep(wait) } catch { return }
            }
        }
    }

    static func isUnreachable(_ error: HubError) -> Bool {
        switch error {
        case .notFound, .notReady, .timedOut, .localNetworkDenied, .handshakeRefused, .versionMismatch, .notPaired: true
        case .badResponse: false
        }
    }

    static func isUnreachableStatus(_ status: SyncStatus) -> Bool {
        if case .awayFromHub = status { return true }
        return false
    }

    /// Runs `work`; returns when it finishes or after `limit`, whichever comes first. The
    /// work keeps running after the limit (its result lands in the outbox and status).
    static func runLimited(_ limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
                           _ work: @escaping @Sendable () async -> Void) async {
        let done = OnceFlag()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = { if done.claim() { c.resume() } }
            Task { await work(); finish() }
            Task { try? await sleep(limit); finish() }
        }
    }
}

/// True for the first ``claim()`` only.
final class OnceFlag: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { d in defer { d = true }; return !d } }
}
