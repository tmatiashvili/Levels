import Foundation
import LevelsModel
import os

/// Reports the accessories connected to this Mac (MAC-003) through ``BatterySyncing``,
/// next to ``BatteryReporter`` which reports the Mac's own battery.
///
/// - ``start()`` scans at once (`.launch`), then on every event the reader reports, and on
///   the accessory poll, the agent's third timer (ADR-0014 rule 5): every 5 minutes while
///   any accessory is connected, otherwise every 15 minutes, with 60 s tolerance. The poll
///   is re-armed after every scan, so there is only ever one pending.
///   - IOKit HID match/termination (R1) and Bluetooth disconnect: scan now.
///   - Bluetooth connect (any device): the poll switches to 5 minutes at once, and scans
///     run 3 s and 15 s later, because AirPods publish their levels a few seconds after
///     connecting. A new connect replaces the pending delayed scans.
/// - The Mac app calls ``report(reason:)`` on wake and on power-source changes (ADR-0015),
///   and ``refresh(userInitiated:)`` on ⌘R / the refresh button (scan now) and on popover
///   open (at most once a minute).
/// - Each connected component becomes one `DeviceBattery` with `parentDeviceId` = this Mac
///   and a UUIDv5 record name (R3, R3a).
/// - A disconnected accessory is simply absent from the scan: nothing is written, the
///   record keeps its last level and `updatedAt`, and the UI shows its age (R4).
/// - Unparseable data is not reported; each distinct problem is logged once per run (R5).
///
/// - While reporting is off ("Remove all my data", SYNC-001 R15a) nothing is scanned or
///   handed to sync: ``start()`` does nothing, and ``report(reason:)``, refreshes, connect
///   events, delayed scans and the poll return at once (the poll is not re-armed).
///
/// Throttling is sync's job (ADR-0008 / `LocalWritePolicy`, judged per record).
public actor AccessoryReporter {
    /// ADR-0014 rule 5 / ADR-0015: poll every 5 min while accessories are connected.
    public static let activeInterval: Duration = .seconds(5 * 60)
    /// Otherwise every 15 min (a fallback; Bluetooth connect events trigger their own scans).
    public static let idleInterval: Duration = .seconds(15 * 60)
    public static let pollTolerance: Duration = .seconds(60)
    /// Scans after a Bluetooth connect, measured from the connect.
    public static let connectScanDelays: [Duration] = [.seconds(3), .seconds(15)]
    /// Popover open (`.foreground`) scans at most this often (UI-004 R7).
    public static let foregroundMinimumGap: Duration = .seconds(60)

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "accessories")

    private let reader: any AccessoryBatteryReader
    private let sync: any BatterySyncing
    private let parentID: @Sendable () -> DeviceID?
    /// SYNC-001 R15a: while off, nothing is scanned or handed to sync.
    private let reporting: ReportingSetting
    /// `(delay, tolerance)` → a sleep whose deadline is fixed when the closure is made.
    private let timer: @Sendable (Duration, Duration) -> @Sendable () async throws -> Void
    /// Time since init on the injected clock (foreground throttle).
    private let elapsed: @Sendable () -> Duration

    private var runTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// The delayed scans after the last Bluetooth connect.
    private var connectScansTask: Task<Void, Never>?
    /// When the last `.foreground` scan ran (``elapsed``).
    private var lastForegroundScan: Duration?
    /// Record IDs seen in the last scan (to log disconnects).
    private(set) var connected: Set<DeviceID> = []
    /// R5: problems already logged this run.
    private(set) var loggedProblems: Set<String> = []
    /// The interval the poll was last armed with.
    private(set) var currentInterval: Duration?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - parentID: this Mac's device ID (ADR-0007); `nil` skips the report.
    ///   - reporting: the same setting ``BatteryReporter`` reads (SYNC-001 R15a).
    ///   - clock: drives the poll; tests pass a manual clock.
    public init<C: Clock<Duration>>(
        reader: any AccessoryBatteryReader,
        sync: any BatterySyncing,
        parentID: @escaping @Sendable () -> DeviceID?,
        reporting: ReportingSetting = .inMemory(),
        clock: C = ContinuousClock()
    ) {
        self.reader = reader
        self.sync = sync
        self.parentID = parentID
        self.reporting = reporting
        self.timer = { delay, tolerance in
            let deadline = clock.now.advanced(by: delay)
            return { try await clock.sleep(until: deadline, tolerance: tolerance) }
        }
        let origin = clock.now
        self.elapsed = { origin.duration(to: clock.now) }
    }

    /// The poll interval after `scan` (ADR-0014 rule 5).
    public static func interval(after scan: AccessoryScan) -> Duration {
        scan.headphonesConnected || !scan.readings.isEmpty ? activeInterval : idleInterval
    }

    // MARK: Lifecycle

    /// Scans with `.launch`, then consumes connect/disconnect events and runs the poll
    /// until ``stop()``. Calling it again while running, or while reporting is off
    /// (SYNC-001 R15a), does nothing.
    public func start() {
        guard runTask == nil, reporting.isEnabled else { return }
        let changes = reader.changes()
        runTask = Task {
            await self.report(reason: .launch)
            for await change in changes {
                if Task.isCancelled { break }
                switch change {
                case .hid, .bluetoothDisconnected:
                    await self.report(reason: .batteryChange)
                case .bluetoothConnected:
                    self.bluetoothConnected()
                }
            }
        }
    }

    /// Bluetooth connect: 5-minute poll now, scans at ``connectScanDelays``.
    private func bluetoothConnected() {
        guard reporting.isEnabled else { return }
        Self.logger.notice("Bluetooth device connected; scanning accessories in 3 s and 15 s")
        armPoll(interval: Self.activeInterval)
        connectScansTask?.cancel()
        let sleeps = Self.connectScanDelays.map { timer($0, .seconds(1)) }
        connectScansTask = Task {
            for sleep in sleeps {
                do { try await sleep() } catch { return }
                guard !Task.isCancelled else { return }
                await self.report(reason: .batteryChange, connectScan: true)
            }
        }
    }

    /// ⌘R or the refresh button (`userInitiated`, `.userRefresh`, always scans), or the
    /// popover opening (`.foreground`, at most once per ``foregroundMinimumGap``).
    public func refresh(userInitiated: Bool) async {
        guard reporting.isEnabled else { return }
        if userInitiated {
            await report(reason: .userRefresh)
            return
        }
        let now = elapsed()
        if let last = lastForegroundScan, now - last < Self.foregroundMinimumGap { return }
        lastForegroundScan = now
        await report(reason: .foreground)
    }

    /// Stops events and the poll ("Remove all my data" turns reporting off).
    public func stop() {
        runTask?.cancel()
        runTask = nil
        pollTask?.cancel()
        pollTask = nil
        connectScansTask?.cancel()
        connectScansTask = nil
        currentInterval = nil
    }

    /// Returns once the scan in progress and any queued behind it have finished
    /// (SYNC-001 R15a: removal runs after the in-flight report, not alongside it).
    public func waitUntilIdle() async {
        await acquire()
        release()
    }

    // MARK: Reporting

    /// Scans and hands every connected component to sync. Returns sync's outcome, or `nil`
    /// when nothing was sent (no accessory connected, no device ID yet, or reporting is off).
    @discardableResult
    public func report(reason: ReportReason) async -> ReportOutcome? {
        await report(reason: reason, connectScan: false)
    }

    /// `connectScan`: a delayed scan after a Bluetooth connect, which keeps the 5-minute poll
    /// even if the new device shows no level yet.
    private func report(reason: ReportReason, connectScan: Bool) async -> ReportOutcome? {
        await acquire()
        defer { release() }
        guard reporting.isEnabled else {  // SYNC-001 R15a: no scan, no poll re-arm
            Self.logger.info("Reporting is off; skipping accessory scan \(reason.rawValue, privacy: .public)")
            return nil
        }
        let scan = await reader.read()
        logNewProblems(scan.problems)
        noteConnections(scan.readings)
        let interval = connectScan ? Self.activeInterval : Self.interval(after: scan)
        armPoll(interval: interval)
        Self.logger.notice("""
            Accessory scan \(reason.rawValue, privacy: .public): \(scan.readings.count) batteries, \
            headphones=\(scan.headphonesConnected), problems=\(scan.problems.count), \
            next poll in \(interval.components.seconds / 60) min
            """)

        guard !scan.readings.isEmpty else { return nil }
        guard let parent = parentID() else {
            Self.logger.info("No device ID yet; skipping accessory report \(reason.rawValue, privacy: .public)")
            return nil
        }
        let devices = scan.readings.map { $0.deviceBattery(parent: parent) }
        let outcome = await sync.report(devices, reason: reason)
        if case .failed = outcome {
            Self.logger.error("Accessory report \(reason.rawValue, privacy: .public) failed")
        }
        return outcome
    }

    private func logNewProblems(_ problems: Set<String>) {
        for problem in problems.subtracting(loggedProblems).sorted() {
            Self.logger.error("Accessory not reported: \(problem, privacy: .public)")
        }
        loggedProblems.formUnion(problems)
    }

    private func noteConnections(_ readings: [AccessoryReading]) {
        let now = Set(readings.map(\.id))
        let gone = connected.subtracting(now).count, new = now.subtracting(connected).count
        if gone > 0 { Self.logger.notice("\(gone) accessory battery(ies) disconnected; keeping their last values") }
        if new > 0 { Self.logger.notice("\(new) accessory battery(ies) connected") }
        connected = now
    }

    // MARK: Poll (ADR-0014 rule 5)

    private func armPoll(interval: Duration) {
        guard runTask != nil else { return }
        pollTask?.cancel()
        currentInterval = interval
        let sleep = timer(interval, Self.pollTolerance)
        pollTask = Task {
            do { try await sleep() } catch { return }
            await self.pollFired()
        }
    }

    private func pollFired() async {
        guard !Task.isCancelled else { return }
        pollTask = nil
        await report(reason: .heartbeat)
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
}
