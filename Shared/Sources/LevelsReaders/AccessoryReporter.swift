import Foundation
import LevelsModel
import os

/// Reports the accessories connected to this Mac (MAC-003) through ``BatterySyncing``,
/// next to ``BatteryReporter`` which reports the Mac's own battery.
///
/// - ``start()`` scans at once (`.launch`), then on every connect or disconnect the
///   reader reports (IOKit HID match/termination, R1), and on the accessory poll, the
///   agent's third timer (ADR-0014 rule 5): every 5 minutes while any accessory is
///   connected, otherwise every 15 minutes, with 60 s tolerance. The poll is re-armed
///   after every scan, so there is only ever one pending.
/// - The Mac app calls ``report(reason:)`` on wake and on power-source changes (ADR-0015).
/// - Each connected component becomes one `DeviceBattery` with `parentDeviceId` = this Mac
///   and a UUIDv5 record name (R3, R3a).
/// - A disconnected accessory is simply absent from the scan: nothing is written, the
///   record keeps its last level and `updatedAt`, and the UI shows its age (R4).
/// - Unparseable data is not reported; each distinct problem is logged once per run (R5).
///
/// Throttling is sync's job (ADR-0008 / `LocalWritePolicy`, judged per record).
public actor AccessoryReporter {
    /// ADR-0014 rule 5 / ADR-0015: poll every 5 min while accessories are connected.
    public static let activeInterval: Duration = .seconds(5 * 60)
    /// Otherwise every 15 min, to notice newly connected AirPods (no connect event without IOBluetooth).
    public static let idleInterval: Duration = .seconds(15 * 60)
    public static let pollTolerance: Duration = .seconds(60)

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "accessories")

    private let reader: any AccessoryBatteryReader
    private let sync: any BatterySyncing
    private let parentID: @Sendable () -> DeviceID?
    private let pollTimer: @Sendable (Duration) -> @Sendable () async throws -> Void

    private var runTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
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
    ///   - clock: drives the poll; tests pass a manual clock.
    public init<C: Clock<Duration>>(
        reader: any AccessoryBatteryReader,
        sync: any BatterySyncing,
        parentID: @escaping @Sendable () -> DeviceID?,
        clock: C = ContinuousClock()
    ) {
        self.reader = reader
        self.sync = sync
        self.parentID = parentID
        self.pollTimer = { interval in
            let deadline = clock.now.advanced(by: interval)
            return { try await clock.sleep(until: deadline, tolerance: Self.pollTolerance) }
        }
    }

    /// The poll interval after `scan` (ADR-0014 rule 5).
    public static func interval(after scan: AccessoryScan) -> Duration {
        scan.headphonesConnected || !scan.readings.isEmpty ? activeInterval : idleInterval
    }

    // MARK: Lifecycle

    /// Scans with `.launch`, then consumes connect/disconnect events and runs the poll
    /// until ``stop()``. Calling it again while running does nothing.
    public func start() {
        guard runTask == nil else { return }
        let changes = reader.changes()
        runTask = Task {
            await self.report(reason: .launch)
            for await _ in changes {
                if Task.isCancelled { break }
                await self.report(reason: .batteryChange)
            }
        }
    }

    /// Stops events and the poll ("Remove all my data" turns reporting off).
    public func stop() {
        runTask?.cancel()
        runTask = nil
        pollTask?.cancel()
        pollTask = nil
        currentInterval = nil
    }

    // MARK: Reporting

    /// Scans and hands every connected component to sync. Returns sync's outcome, or `nil`
    /// when nothing was sent (no accessory connected, or no device ID yet).
    @discardableResult
    public func report(reason: ReportReason) async -> ReportOutcome? {
        await acquire()
        defer { release() }
        let scan = await reader.read()
        logNewProblems(scan.problems)
        noteConnections(scan.readings)
        armPoll(after: scan)
        Self.logger.notice("""
            Accessory scan \(reason.rawValue, privacy: .public): \(scan.readings.count) batteries, \
            headphones=\(scan.headphonesConnected), problems=\(scan.problems.count), \
            next poll in \(Self.interval(after: scan).components.seconds / 60) min
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

    private func armPoll(after scan: AccessoryScan) {
        guard runTask != nil else { return }
        pollTask?.cancel()
        let interval = Self.interval(after: scan)
        currentInterval = interval
        let sleep = pollTimer(interval)
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
