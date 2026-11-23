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
/// remove (SYNC-001 R15/R15a). ``ReportOutcome/uploaded`` means "written to the cache".
public actor LocalOnlySyncService: BatterySyncing {
    /// SYNC-001 R8a: at most one widget reload per 60 s.
    public static let widgetReloadInterval: TimeInterval = 60

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: LevelsLog.syncCategory)

    private let cache: SnapshotCache
    private let policy: LocalWritePolicy
    private let widgetReloader: @Sendable () -> Void
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
    // Serialises `report` and held-write flushes, which suspend while the cache is written.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - cache: the App Group snapshot cache (ADR-0009).
    ///   - widgetReloader: asks WidgetKit to reload, e.g. `{ WidgetCenter.shared.reloadAllTimelines() }`
    ///     in the app target. Called at most once per 60 s (SYNC-001 R8a).
    ///   - clock: drives held writes and the trailing widget reload; tests pass a manual clock.
    public init<C: Clock<Duration>>(
        cache: SnapshotCache,
        policy: LocalWritePolicy = LocalWritePolicy(),
        widgetReloader: @escaping @Sendable () -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        clock: C = ContinuousClock()
    ) {
        self.cache = cache
        self.policy = policy
        self.widgetReloader = widgetReloader
        self.now = now
        self.timer = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    // MARK: BatterySyncing

    /// Always `.idle`: there is no account or network state to report.
    /// `SyncStatus` has no local-only case yet; see ``isLocalOnly``.
    public var status: SyncStatus { .idle }

    /// True for this stand-in; the UI uses it to say "local only, no iCloud".
    public nonisolated var isLocalOnly: Bool { true }

    /// Writes each reading into the cache per ``LocalWritePolicy``, judged per record.
    /// The first non-accessory reading is this device (`ownDeviceID`).
    /// - Returns: `.uploaded` when something was written now, else `.held(until:)` with the
    ///   earliest pending write, else `.skipped`; `.failed(retryAt: nil)` when the cache
    ///   write failed (the next trigger tries again).
    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        await acquire()
        defer { release() }
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
    public func start() async {
        let cache = cache
        do {
            try await Task.detached(priority: .utility) {
                try cache.update { $0.syncStatus = .idle }
            }.value
        } catch {
            Self.logger.error("Cache update failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// There is nothing to fetch: re-reads the cache and returns whether it is readable.
    /// The UI reloads from the cache itself; this keeps SYNC-001's `refresh(_:)` call shape.
    @discardableResult
    public func refresh(_ reason: RefreshReason) async -> Bool {
        let cache = cache
        return await Task.detached(priority: .utility) { cache.read() != nil }.value
    }

    // MARK: Writing

    /// Upserts `slots` into the cache in one coordinated write (SYNC-002 R13), then
    /// requests a widget reload if `devices` changed (SYNC-001 R8a).
    private func write(_ slots: [Pending]) async -> Bool {
        let cache = cache
        let values = slots.map(\.value)
        let ownID = slots.first(where: \.isOwn)?.value.id
        do {
            let changed = try await Task.detached(priority: .utility) {
                try cache.update { file in
                    let before = file.devices
                    for value in values {
                        if let i = file.devices.firstIndex(where: { $0.id == value.id }) {
                            file.devices[i] = value
                        } else {
                            file.devices.append(value)
                        }
                    }
                    file.devices = SnapshotFile.sorted(file.devices)
                    if let ownID { file.ownDeviceID = ownID }
                    file.syncStatus = .idle
                    return file.devices != SnapshotFile.sorted(before)
                }
            }.value
            let t = now()
            for value in values { written[value.id] = Written(value: value, at: t) }
            if changed { requestWidgetReload() }
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

    /// The first request in a quiet period reloads at once; requests within 60 s of the
    /// last reload mark one trailing reload at the end of the window.
    private func requestWidgetReload() {
        let t = now()
        if let last = lastReloadAt, t.timeIntervalSince(last) < Self.widgetReloadInterval {
            guard trailingReloadTask == nil else { return }
            let sleep = timer(Self.duration(last.addingTimeInterval(Self.widgetReloadInterval).timeIntervalSince(t)))
            trailingReloadTask = Task {
                try? await sleep()
                self.fireTrailingReload()
            }
        } else {
            lastReloadAt = t
            widgetReloader()
        }
    }

    private func fireTrailingReload() {
        trailingReloadTask = nil
        lastReloadAt = now()
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
