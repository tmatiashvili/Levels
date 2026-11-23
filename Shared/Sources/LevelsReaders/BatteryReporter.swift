import Foundation
import LevelsModel
import os

/// Why ``BatteryReporter/reportNow(reason:)`` failed (RPT-001).
public enum ReportError: Error, Sendable, Equatable {
    /// Sync status is `.signedOut` or `.restricted`. The reading still reached the cache.
    case iCloudUnavailable
    /// Sync answered `.failed`.
    case syncFailed
}

/// Turns this device's battery readings into ``DeviceBattery`` values and hands them
/// to sync through ``BatterySyncing`` (ADR-0003, ADR-0010, RPT-001, MAC-002).
///
/// Mac use (MAC-002): ``start()`` reports `.launch` (R6a), then consumes
/// `reader.changes()` (R6b IOPS changes and R6c Low Power Mode, filtered by R7) and
/// runs the 30-minute heartbeat (R6f). MAC-001 and UI-004 call ``report(reason:)``
/// with `.sleep`, `.wake`, `.pushWake` and `.userRefresh` (R6d–e3).
///
/// Throttling is sync's job (ADR-0008); the reporter only drops unchanged change
/// events (R7) and read failures (R10). Reports run one at a time, in call order.
public actor BatteryReporter {
    /// MAC-002 R6f: every 30 minutes, with 5 minutes of timer tolerance.
    public static let heartbeatInterval: Duration = .seconds(30 * 60)
    public static let heartbeatTolerance: Duration = .seconds(5 * 60)

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "reporting")

    private let reader: any BatteryReader
    private let sync: any BatterySyncing
    private let kind: DeviceKind
    private let deviceID: @Sendable () -> DeviceID?
    private let deviceName: @Sendable () -> String
    private let log: ReportLog
    private let now: @Sendable () -> Date
    /// Returns a heartbeat sleep whose deadline is fixed when this is called.
    private let heartbeatTimer: @Sendable () -> @Sendable () async throws -> Void

    /// The last reading handed to sync; R7 compares change events against it.
    private var lastOffered: BatteryReading?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// R10: read failures are logged once per run.
    private(set) var readFailureLogCount = 0

    // A FIFO gate so overlapping triggers report one after the other (RPT-001 AC6)
    // even though `await sync.report` lets the actor take other calls meanwhile.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - kind: this device's kind (`.mac` here; `.iphone`, `.ipad`, `.watch` for RPT). Never `.accessory`.
    ///   - deviceID: this device's stable ID (ADR-0007, `DeviceIdentityProviding` in SYNC-001).
    ///     `nil` (Keychain not readable yet) skips the report.
    ///   - deviceName: the name to write (SYNC-002 R17), read on every report so a rename
    ///     reaches sync. Typically `DefaultDeviceName.resolved(kind:thisDeviceName:)`.
    ///   - clock: drives the heartbeat; tests pass a manual clock.
    public init<C: Clock<Duration>>(
        reader: any BatteryReader,
        sync: any BatterySyncing,
        kind: DeviceKind,
        deviceID: @escaping @Sendable () -> DeviceID?,
        deviceName: (@Sendable () -> String)? = nil,
        log: ReportLog = .inMemory(),
        now: @escaping @Sendable () -> Date = Date.init,
        clock: C = ContinuousClock()
    ) {
        precondition(kind != .accessory, "BatteryReporter reports a device's own battery, not an accessory")
        self.reader = reader
        self.sync = sync
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName ?? { DefaultDeviceName.current(kind: kind) }
        self.log = log
        self.now = now
        self.heartbeatTimer = {
            let deadline = clock.now.advanced(by: Self.heartbeatInterval)
            return { try await clock.sleep(until: deadline, tolerance: Self.heartbeatTolerance) }
        }
    }

    /// MAC-002 Design shape: the ID comes from `identity` (ADR-0007) and the name from
    /// `preferences.thisDeviceName`, else the default name (SYNC-002 R17), on every report.
    public init<C: Clock<Duration>>(
        reader: any BatteryReader,
        sync: any BatterySyncing,
        kind: DeviceKind,
        identity: any DeviceIdentityProviding,
        preferences: any DisplayPreferencesStore,
        log: ReportLog = .inMemory(),
        now: @escaping @Sendable () -> Date = Date.init,
        clock: C = ContinuousClock()
    ) {
        self.init(reader: reader, sync: sync, kind: kind,
                  deviceID: { (try? identity.currentDeviceID()) ?? nil },
                  deviceName: { DefaultDeviceName.resolved(kind: kind, thisDeviceName: preferences.load().thisDeviceName) },
                  log: log, now: now, clock: clock)
    }

    // MARK: Lifecycle (MAC-002 R6)

    /// Reports `.launch` (R6a), then consumes the reader's changes (R6b, R6c) and runs
    /// the heartbeat (R6f) until ``stop()``. Calling it again while running does nothing.
    public func start() {
        guard runTask == nil else { return }
        let changes = reader.changes()
        runTask = Task {
            await self.report(reason: .launch)
            if self.heartbeatTask == nil { self.armHeartbeat() }  // not armed by an accepted launch write
            for await reading in changes {
                if Task.isCancelled { break }
                await self.handleChange(reading)
            }
        }
    }

    /// Stops consuming changes and cancels the heartbeat.
    public func stop() {
        runTask?.cancel()
        runTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: Reporting

    /// Reads and reports with `reason`, without the R7 change filter. MAC-001 calls it
    /// with `.sleep`, `.wake` and `.pushWake`, UI-004 with `.userRefresh`. Errors are logged.
    @discardableResult
    public func report(reason: ReportReason) async -> ReportOutcome? {
        do {
            return try await reportNowOutcome(reason: reason)?.outcome
        } catch {
            Self.logger.error("Report \(reason.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads, maps to `DeviceBattery` (SYNC-002 R16/R17) and calls `sync.report([device], reason:)`
    /// (RPT-001). Returns the reading it sent, or `nil` when nothing was sent (read failure
    /// or no device ID).
    /// - Throws: ``ReportError/syncFailed`` when sync answers `.failed`;
    ///   ``ReportError/iCloudUnavailable`` when sync status is `.signedOut` or `.restricted`.
    @discardableResult
    public func reportNow(reason: ReportReason) async throws(ReportError) -> BatteryReading? {
        try await reportNowOutcome(reason: reason)?.reading
    }

    private func reportNowOutcome(reason: ReportReason) async throws(ReportError) -> (reading: BatteryReading, outcome: ReportOutcome)? {
        await acquire()
        defer { release() }
        let reading = await reader.read()
        guard !reading.isReadFailure else {
            noteReadFailure()
            return nil
        }
        guard let outcome = await offer(reading, reason: reason) else { return nil }
        if case .failed = outcome { throw .syncFailed }
        switch await sync.status {
        case .signedOut, .restricted: throw .iCloudUnavailable
        default: break
        }
        return (reading, outcome)
    }

    /// R6b/R6c with the R7 filter and R8 reasons: drop failures (R10) and readings whose
    /// level, power state and Low Power Mode equal the last offered one; otherwise
    /// `.chargerChange` when the power state changed, else `.batteryChange`.
    private func handleChange(_ reading: BatteryReading) async {
        await acquire()
        defer { release() }
        guard !reading.isReadFailure else {
            noteReadFailure()
            return
        }
        let reason: ReportReason
        if let last = lastOffered {
            guard reading.differsInValues(from: last) else { return }
            reason = reading.powerState != last.powerState ? .chargerChange : .batteryChange
        } else {
            reason = .batteryChange
        }
        if case .failed = await offer(reading, reason: reason) {
            Self.logger.error("Report \(reason.rawValue, privacy: .public) failed")
        }
    }

    /// Maps and hands one reading to sync. Returns `nil` when there is no device ID yet.
    private func offer(_ reading: BatteryReading, reason: ReportReason) async -> ReportOutcome? {
        guard let id = deviceID() else {
            Self.logger.info("No device ID yet; skipping report \(reason.rawValue, privacy: .public)")
            return nil
        }
        let flags = reading.powerState.chargingFlags
        let device = DeviceBattery(
            id: id,
            name: deviceName(),
            kind: kind,
            level: reading.level,
            isCharging: flags.isCharging,
            isPluggedIn: flags.isPluggedIn,
            isLowPowerMode: reading.isLowPowerMode,
            updatedAt: reading.readAt
        )
        lastOffered = reading
        let outcome = await sync.report([device], reason: reason)
        switch outcome {
        case .failed:
            break  // RPT-001 AC4: the log is left unchanged
        case .uploaded:
            log.record(reason, at: now())
            armHeartbeat()  // the next heartbeat is due 30 min after this accepted write (ADR-0008 W6)
        case .held, .skipped:
            log.record(reason, at: now())
        }
        return outcome
    }

    private func noteReadFailure() {
        guard readFailureLogCount == 0 else { return }
        readFailureLogCount += 1
        Self.logger.error("Battery read failed; nothing offered, retrying on the next trigger")
    }

    // MARK: Heartbeat (MAC-002 R6f, R9)

    /// (Re)starts the 30-minute heartbeat while running. Re-armed after every write sync
    /// accepted, so a heartbeat arrives once the last write is 30 minutes old.
    private func armHeartbeat() {
        guard runTask != nil else { return }
        heartbeatTask?.cancel()
        let sleep = heartbeatTimer()
        heartbeatTask = Task {
            do {
                try await sleep()
            } catch {
                return  // cancelled
            }
            await self.heartbeatFired()
        }
    }

    private func heartbeatFired() async {
        guard !Task.isCancelled else { return }
        heartbeatTask = nil
        await report(reason: .heartbeat)
        if heartbeatTask == nil { armHeartbeat() }  // not re-armed by an accepted write
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
