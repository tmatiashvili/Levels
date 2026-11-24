import Foundation
import LevelsModel
import os

/// The free-team stand-in for `BatterySyncService` (SYNC-001): implements
/// ``BatterySyncing`` with no CloudKit, no push and no network (owner decision K,
/// 2026-11-23: no paid Apple Developer Program yet, so no iCloud entitlement).
///
/// `report` writes this device's readings (and later its accessories', MAC-003) into the
/// App Group ``SnapshotCache`` that the UI and the widgets read, following
/// ``LocalWritePolicy`` (ADR-0008 adapted). Callers depend only on ``BatterySyncing``,
/// so the app swaps in `BatterySyncService` once the owner enrolls, without touching
/// the reporters or the UI.
///
/// What it does not do: upload, fetch, bootstrap, account handling, `lastWritten`
/// (that field means "accepted by the server", so it stays empty for SYNC-001 to fill),
/// single-record remove (SYNC-001 R15). ``ReportOutcome/uploaded`` means "written to the cache".
/// ``removeAllData()`` is the local half of SYNC-001 R15a.
public actor LocalOnlySyncService: BatterySyncing {
    /// SYNC-001 R8a: at most one widget reload per 60 s.
    public static let widgetReloadInterval: TimeInterval = 60
    /// SYNC-001 R8a (lead's call 17): a write that changes only `updatedAt` reloads widgets
    /// when the stale moment the widget last received is less than this far away.
    public static let staleReloadLead: TimeInterval = 35 * 60

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: LevelsLog.syncCategory)

    private let cache: SnapshotCache
    private let policy: LocalWritePolicy
    private let reporting: ReportingSetting
    private let widgetReloader: @Sendable () -> Void
    /// NET-003 Design: called after each successful write that holds this device's own
    /// reading (direct or held flush); the hub client's outbox listens.
    private let onOwnWrite: @Sendable (DeviceBattery) -> Void
    /// What writes stamp into `SnapshotFile.syncStatus`. `.localOnly` unless a wrapping
    /// service (``LocalNetworkSyncService``) sets another with ``setStatus(_:lastFetchAt:)``.
    private var currentStatus: SyncStatus = .localOnly
    private let now: @Sendable () -> Date
    /// Returns a sleep that ends `duration` after *now* (the deadline is fixed when this is
    /// called, not when the returned closure starts running).
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    private struct Written { var value: DeviceBattery; var at: Date }
    private struct Pending { var value: DeviceBattery; var due: Date; var isOwn: Bool }

    /// Last value this process wrote to the cache, per record. In memory only: after a
    /// relaunch the first report writes at once (W1), and `.launch` is urgent anyway.
    private var written: [DeviceID: Written] = [:]
    /// One pending slot per record; the latest reading wins (ADR-0008 coalescing).
    private var pending: [DeviceID: Pending] = [:]
    private var flushTask: Task<Void, Never>?
    private var lastReloadAt: Date?
    private var trailingReloadTask: Task<Void, Never>?
    /// The cache's devices after this process's last write or reset; `nil` before the first.
    private var cachedDevices: [DeviceBattery]?
    /// What widgets got at the last reload this process requested; `nil` = unknown.
    private var widgetDevices: [DeviceBattery]?
    // Serialises `report` and held-write flushes, which suspend while the cache is written.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - cache: the App Group snapshot cache (ADR-0009).
    ///   - reporting: SYNC-001 R15a; ``removeAllData()`` turns it off and `report` writes
    ///     nothing while it is off.
    ///   - widgetReloader: asks WidgetKit to reload, e.g. `{ WidgetCenter.shared.reloadAllTimelines() }`
    ///     in the app target. Called at most once per 60 s (SYNC-001 R8a).
    ///   - clock: drives held writes and the trailing widget reload; tests pass a manual clock.
    public init<C: Clock<Duration>>(
        cache: SnapshotCache,
        policy: LocalWritePolicy = LocalWritePolicy(),
        reporting: ReportingSetting = .inMemory(),
        widgetReloader: @escaping @Sendable () -> Void,
        onOwnWrite: @escaping @Sendable (DeviceBattery) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init,
        clock: C = ContinuousClock()
    ) {
        self.onOwnWrite = onOwnWrite
        self.cache = cache
        self.policy = policy
        self.reporting = reporting
        self.widgetReloader = widgetReloader
        self.now = now
        self.timer = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    // MARK: BatterySyncing

    /// ``SyncStatus/localOnly`` on its own; a wrapping hub service may set another.
    public var status: SyncStatus { currentStatus }

    /// Hub mode (NET-003 R3, R9): records a status (and, when given, the last good contact
    /// with the Mac) in the cache so the UI and widgets read it. Later writes keep it. A
    /// status change requests a widget reload (the away footer, NET-004 R13). Nothing is
    /// written while reporting is off. Runs under the serial gate.
    public func setStatus(_ status: SyncStatus, lastFetchAt: Date? = nil) async {
        await acquire()
        defer { release() }
        let changed = status != currentStatus
        currentStatus = status
        guard reporting.isEnabled else { return }
        let cache = cache
        do {
            let fileChanged = try await Task.detached(priority: .utility) {
                try cache.update { (file: inout SnapshotFile) -> Bool in
                    let before = (file.syncStatus, file.lastFetchAt)
                    file.syncStatus = status
                    if let lastFetchAt { file.lastFetchAt = lastFetchAt }
                    return before.0 != file.syncStatus || before.1 != file.lastFetchAt
                }
            }.value
            if changed && fileChanged { requestWidgetReload() }
        } catch {
            Self.logger.error("Cache status update failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes each reading into the cache per ``LocalWritePolicy``, judged per record.
    /// The first non-accessory reading is this device (`ownDeviceID`).
    /// - Returns: `.uploaded` when something was written now, else `.held(until:)` with the
    ///   earliest pending write, else `.skipped`; `.failed(retryAt: nil)` when the cache
    ///   write failed (the next trigger tries again). `.skipped` while reporting is off (R15a).
    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        await acquire()
        defer { release() }
        guard reporting.isEnabled else { return .skipped }  // R15a, checked under the gate
        let t = now()
        let ownID = readings.first(where: { $0.kind != .accessory })?.id
        var due: [Pending] = []
        for reading in readings {
            let last = written[reading.id]
            let decision = policy.decide(new: reading, reason: reason, lastWritten: last?.value, lastWriteAt: last?.at, now: t)
            let decidedDue: Date? = switch decision {
            case .writeNow: t
            case .writeAt(let date): date
            case .skip: nil
            }
            let isOwn = reading.id == ownID
            // Coalescing: the latest reading replaces the pending one and keeps the earlier due time.
            let dueAt: Date? = switch (pending[reading.id]?.due, decidedDue) {
            case let (old?, new?): min(old, new)
            case let (old?, nil): old
            case let (nil, new): new
            }
            guard let dueAt else { continue }
            let slot = Pending(value: reading, due: dueAt, isOwn: isOwn)
            if dueAt <= t {
                pending[reading.id] = nil
                due.append(slot)
            } else {
                pending[reading.id] = slot
            }
        }

        var outcome: ReportOutcome = .skipped
        if !due.isEmpty {
            outcome = await write(due) ? .uploaded : .failed(retryAt: nil)
        }
        scheduleFlush()
        if case .skipped = outcome, let next = pending.values.map(\.due).min() {
            outcome = .held(until: next)
        }
        return outcome
    }

    // MARK: Local surface (SYNC-001 shape)

    /// Records the local-only status in the cache so widgets read it (SYNC-001 R21).
    /// While reporting is off (R15a) it writes nothing, so a relaunch after "Remove all my
    /// data" does not bring the deleted cache file back.
    public func start() async {
        guard reporting.isEnabled else { return }
        let cache = cache
        let status = currentStatus
        do {
            try await Task.detached(priority: .utility) {
                try cache.update { $0.syncStatus = status }
            }.value
        } catch {
            Self.logger.error("Cache update failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// There is nothing to fetch: re-reads the cache and returns whether it is readable
    /// (``BatterySyncing/refresh(_:)``). The UI reloads from the cache itself.
    @discardableResult
    public func refresh(_ reason: RefreshReason) async -> Bool {
        let cache = cache
        return await Task.detached(priority: .utility) { cache.read() != nil }.value
    }

    /// SYNC-001 R15a, local half: under the gate (after any report or flush in progress),
    /// resets the cache, drops held writes and what was written, requests a widget reload
    /// and turns reporting off. A failed reset throws and changes nothing.
    public func removeAllData() async throws {
        await acquire()
        defer { release() }
        let cache = cache
        try await Task.detached(priority: .utility) { try cache.reset() }.value
        flushTask?.cancel()
        flushTask = nil
        pending = [:]
        written = [:]
        cachedDevices = []
        reporting.setEnabled(false)
        requestWidgetReload()
    }

    /// Turns reporting back on (R15a). The next report writes at once (W1: nothing written).
    public func resumeReporting() {
        reporting.setEnabled(true)
    }

    // MARK: Records from elsewhere (NET-001 Design, ADR-0020 Decision 6)

    /// Merges records written elsewhere (SYNC-002 R14: newer `updatedAt` wins, the incoming
    /// one on a tie) and applies the R8a widget reload rule. Skips `LocalWritePolicy`: the
    /// writer already throttled (ADR-0008 on the iPhone).
    ///
    /// `replacingAllExcept: nil` = partial (keep everything else). Non-nil = full: drop
    /// entries the incoming set lacks, except the IDs given (the own device, whose local copy
    /// also always wins over the incoming one: `SnapshotFile.merge`). Runs under the
    /// serial gate. Does nothing while reporting is off (NET-001 R10). Returns whether
    /// `devices` changed.
    @discardableResult
    public func ingest(_ records: [DeviceBattery], replacingAllExcept keep: Set<DeviceID>?) async -> Bool {
        await acquire()
        defer { release() }
        guard reporting.isEnabled else { return false }
        let cache = cache
        do {
            let (before, after) = try await Task.detached(priority: .utility) {
                try cache.update { file in
                    let before = SnapshotFile.sorted(file.devices)
                    file.merge(fetched: records, isFullFetch: keep != nil, ownIDs: keep ?? [])
                    return (before, file.devices)
                }
            }.value
            cachedDevices = after
            if Self.needsWidgetReload(before: before, after: after, received: widgetDevices, now: now()) {
                requestWidgetReload()
            }
            return before != after
        } catch {
            Self.logger.error("Cache ingest failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Removes one record from the cache (`DELETE /v1/devices/me`, NET-002 R9) and drops any
    /// held write for it. R8a reload rule. Runs under the serial gate.
    public func removeLocal(_ id: DeviceID) async {
        await acquire()
        defer { release() }
        pending[id] = nil
        written[id] = nil
        let cache = cache
        do {
            let (before, after) = try await Task.detached(priority: .utility) {
                try cache.update { file in
                    let before = SnapshotFile.sorted(file.devices)
                    file.devices.removeAll { $0.id == id }
                    return (before, file.devices)
                }
            }.value
            cachedDevices = after
            if Self.needsWidgetReload(before: before, after: after, received: widgetDevices, now: now()) {
                requestWidgetReload()
            }
        } catch {
            Self.logger.error("Cache remove failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The hidden set changed: widgets show it, so they reload (R8a, coalesced).
    public func displayPreferencesChanged() {
        requestWidgetReload()
    }

    // MARK: Writing

    /// Upserts `slots` into the cache in one coordinated write (SYNC-002 R13), then
    /// requests a widget reload if what widgets show changed (SYNC-001 R8a).
    private func write(_ slots: [Pending]) async -> Bool {
        let cache = cache
        let values = slots.map(\.value)
        let own = slots.first(where: \.isOwn)?.value
        let ownID = own?.id
        let status = currentStatus
        do {
            let (before, after) = try await Task.detached(priority: .utility) {
                try cache.update { file in
                    let before = SnapshotFile.sorted(file.devices)
                    for value in values {
                        if let i = file.devices.firstIndex(where: { $0.id == value.id }) {
                            file.devices[i] = value
                        } else {
                            file.devices.append(value)
                        }
                    }
                    file.devices = SnapshotFile.sorted(file.devices)
                    if let ownID { file.ownDeviceID = ownID }
                    file.syncStatus = status
                    return (before, file.devices)
                }
            }.value
            let t = now()
            for value in values { written[value.id] = Written(value: value, at: t) }
            if let own { onOwnWrite(own) }
            cachedDevices = after
            if Self.needsWidgetReload(before: before, after: after, received: widgetDevices, now: t) {
                requestWidgetReload()
            }
            return true
        } catch {
            // `written` is untouched, so it still matches the cache and the next report
            // for these records is judged against what the cache really holds.
            Self.logger.error("Cache write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Arms one timer for the earliest pending write (only while the process lives).
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = nil
        guard let next = pending.values.map(\.due).min() else { return }
        let sleep = timer(Self.duration(next.timeIntervalSince(now())))
        flushTask = Task {
            do { try await sleep() } catch { return }
            await self.flushDue()
        }
    }

    private func flushDue() async {
        guard !Task.isCancelled else { return }
        flushTask = nil
        await acquire()
        defer { release() }
        let t = now()
        let due = pending.values.filter { $0.due <= t }
        for slot in due { pending[slot.value.id] = nil }
        if !due.isEmpty { _ = await write(due) }
        if flushTask == nil { scheduleFlush() }
    }

    // MARK: Widget reloads (SYNC-001 R8a)

    /// Lead's call 17: reload only when what a widget shows changed (device set, level,
    /// charging, plugged in, Low Power Mode, name, kind, accessory grouping), or when a
    /// record's stale moment moved and the one widgets last received is less than
    /// ``staleReloadLead`` away. `received == nil` (no reload yet in this process): any
    /// change of `devices` reloads.
    static func needsWidgetReload(before: [DeviceBattery], after: [DeviceBattery],
                                  received: [DeviceBattery]?, now: Date) -> Bool {
        guard before != after else { return false }
        guard let received else { return true }
        let shown = Dictionary(received.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard Set(shown.keys) == Set(after.map(\.id)) else { return true }
        for d in after {
            guard let r = shown[d.id] else { return true }
            if d.level != r.level || d.isCharging != r.isCharging || d.isPluggedIn != r.isPluggedIn
                || d.isLowPowerMode != r.isLowPowerMode || d.name != r.name || d.kind != r.kind
                || d.accessory != r.accessory {
                return true
            }
            let staleAt = FreshnessRule.staleDate(for: r)
            if FreshnessRule.staleDate(for: d) != staleAt, staleAt < now.addingTimeInterval(staleReloadLead) {
                return true
            }
        }
        return false
    }

    /// The first request in a quiet period reloads at once; requests within 60 s of the
    /// last reload mark one trailing reload at the end of the window.
    private func requestWidgetReload() {
        let t = now()
        if let last = lastReloadAt, t.timeIntervalSince(last) < Self.widgetReloadInterval {
            guard trailingReloadTask == nil else { return }
            let sleep = timer(Self.duration(last.addingTimeInterval(Self.widgetReloadInterval).timeIntervalSince(t)))
            trailingReloadTask = Task {
                do { try await sleep() } catch { return }  // cancelled: flushWidgetReload fired it
                guard !Task.isCancelled else { return }
                self.fireTrailingReload()
            }
        } else {
            fireReload(at: t)
        }
    }

    /// Fires a held trailing reload now, if there is one; else does nothing (no extra reload).
    /// For the app going to the background, or the end of a background refresh: the process
    /// is suspended soon after, and the trailing reload's timer would never fire, leaving the
    /// widget on the older data until its own next reload.
    public func flushWidgetReload() {
        guard let task = trailingReloadTask else { return }
        task.cancel()
        fireTrailingReload()
    }

    private func fireTrailingReload() {
        trailingReloadTask = nil
        fireReload(at: now())
    }

    private func fireReload(at t: Date) {
        lastReloadAt = t
        if let cachedDevices { widgetDevices = cachedDevices }
        widgetReloader()
    }

    // MARK: Serial gate

    private func acquire() async {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func duration(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((max(0, seconds) * 1000).rounded(.up)))
    }
}
