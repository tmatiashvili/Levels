import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

/// Records what the reporter hands to sync.
actor FakeSync: BatterySyncing {
    struct Call: Sendable { var devices: [DeviceBattery]; var reason: ReportReason }
    private(set) var calls: [Call] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    var outcome: ReportOutcome = .uploaded
    var currentStatus: SyncStatus = .idle
    var yieldsPerReport = 0

    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        for _ in 0..<yieldsPerReport { await Task.yield() }
        calls.append(Call(devices: readings, reason: reason))
        inFlight -= 1
        return outcome
    }

    var status: SyncStatus { currentStatus }
    var reasons: [ReportReason] { calls.map(\.reason) }
    func set(outcome: ReportOutcome) { self.outcome = outcome }
    func set(status: SyncStatus) { currentStatus = status }
    func set(yields: Int) { yieldsPerReport = yields }
}

@Suite("MAC-002 BatteryReporter")
struct BatteryReporterTests {
    let clock = ManualClock()
    let sync = FakeSync()
    let log = ReportLog.inMemory()
    let id = DeviceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    func reading(_ level: Int?, _ state: BatteryReading.PowerState = .unplugged, lowPower: Bool = false) -> BatteryReading {
        BatteryReading(level: level, powerState: state, isLowPowerMode: lowPower, readAt: clock.date)
    }

    func reporter(_ reader: FixedBatteryReader, deviceID: DeviceID?? = nil) -> BatteryReporter {
        let id = deviceID ?? self.id
        let clock = clock
        return BatteryReporter(reader: reader, sync: sync, kind: .mac, deviceID: { id },
                               deviceName: { "Office Mac" }, log: log, now: { clock.date }, clock: clock)
    }

    /// Starts the reporter and waits for the `.launch` report and the armed heartbeat.
    func started(_ reader: FixedBatteryReader) async -> BatteryReporter {
        let r = reporter(reader)
        await r.start()
        await waitFor { [sync, clock] in await sync.calls.count == 1 && clock.sleeperCount == 1 }
        return r
    }

    // MARK: R6a, R8

    @Test func R6a_startReportsLaunch() async {
        let reader = FixedBatteryReader(reading(66, .charging))
        let r = await started(reader)
        #expect(await sync.reasons == [.launch])
        let device = await sync.calls[0].devices[0]
        #expect(device.id == id)
        #expect(device.kind == .mac)
        #expect(device.name == "Office Mac")
        #expect(device.level == 66)
        #expect(device.isCharging && device.isPluggedIn == true)
        #expect(device.isLowPowerMode == false)
        #expect(device.updatedAt == clock.date)
        await r.stop()
    }

    @Test(arguments: [ReportReason.wake, .sleep, .pushWake, .userRefresh])
    func AC4_R8_explicitReasonsPassThrough(reason: ReportReason) async {
        let r = reporter(FixedBatteryReader(reading(50)))
        await r.report(reason: reason)
        await r.report(reason: reason)  // explicit reports skip the R7 filter
        #expect(await sync.reasons == [reason, reason])
    }

    @Test func R8_urgencyMatchesSpec() {
        let urgent: Set<ReportReason> = [.launch, .chargerChange, .wake, .sleep, .userRefresh]
        for reason in [ReportReason.launch, .chargerChange, .batteryChange, .wake, .sleep, .pushWake, .userRefresh, .heartbeat] {
            #expect(reason.isUrgent == urgent.contains(reason), "\(reason)")
        }
    }

    // MARK: R7 change filter (AC4)

    @Test func AC4_unchangedChangeEventIsDropped() async {
        let reader = FixedBatteryReader(reading(50))
        let r = await started(reader)
        reader.emit(reading(50))          // same values (IOPS time-remaining update)
        reader.emit(reading(49))          // then a real change
        await waitFor { [sync] in await sync.calls.count == 2 }
        await settle()
        #expect(await sync.reasons == [.launch, .batteryChange])
        #expect(await sync.calls[1].devices[0].level == 49)
        await r.stop()
    }

    @Test func AC4_levelChangeIsBatteryChange() async {
        let reader = FixedBatteryReader(reading(50))
        let r = await started(reader)
        reader.emit(reading(51))
        await waitFor { [sync] in await sync.calls.count == 2 }
        #expect(await sync.reasons.last == .batteryChange)
        await r.stop()
    }

    @Test func AC4_powerStateChangeIsChargerChange() async {
        let reader = FixedBatteryReader(reading(50))
        let r = await started(reader)
        reader.emit(reading(50, .charging))
        await waitFor { [sync] in await sync.calls.count == 2 }
        #expect(await sync.reasons.last == .chargerChange)
        await r.stop()
    }

    @Test func R6c_lowPowerModeChangeIsBatteryChange() async {
        let reader = FixedBatteryReader(reading(50))
        let r = await started(reader)
        reader.emit(reading(50, lowPower: true))
        await waitFor { [sync] in await sync.calls.count == 2 }
        #expect(await sync.reasons.last == .batteryChange)
        #expect(await sync.calls.last?.devices[0].isLowPowerMode == true)
        await r.stop()
    }

    @Test func R7_comparesAgainstLastOfferedIncludingExplicitReports() async {
        let reader = FixedBatteryReader(reading(50))
        let r = await started(reader)
        reader.set(reading(40))
        await r.report(reason: .wake)     // offers 40
        reader.emit(reading(40))          // equal to the last offered → dropped
        reader.emit(reading(40, .charging))
        await waitFor { [sync] in await sync.calls.count == 3 }
        await settle()
        #expect(await sync.reasons == [.launch, .wake, .chargerChange])
        await r.stop()
    }

    // MARK: R5, R10 (AC3)

    @Test func R5_desktopMacIsReportedWithNoLevel() async {
        let r = reporter(FixedBatteryReader(MacPowerMapper.reading(from: [], lowPowerMode: false, now: clock.date)))
        await r.report(reason: .launch)
        let device = await sync.calls[0].devices[0]
        #expect(device.kind == .mac)
        #expect(device.level == nil)
        #expect(device.isCharging == false)
        #expect(device.isPluggedIn == true)
    }

    @Test func AC3_R10_readFailureOffersNothingAndLogsOnce() async throws {
        let failure = reading(nil, .unknown)
        let reader = FixedBatteryReader(failure)
        let r = reporter(reader)
        await r.start()                // .launch: nothing offered
        await waitFor { [clock] in clock.sleeperCount == 1 }
        #expect(await sync.calls.isEmpty)
        reader.emit(failure)
        reader.emit(failure)
        #expect(try await r.reportNow(reason: .wake) == nil)
        reader.emit(reading(30))       // the next good reading goes through
        await waitFor { [sync] in await sync.calls.count == 1 }
        #expect(await sync.reasons == [.batteryChange])
        #expect(await r.readFailureLogCount == 1)
        await r.stop()
    }

    @Test func noDeviceIDSkipsReport() async throws {
        let r = reporter(FixedBatteryReader(reading(50)), deviceID: .some(nil))
        #expect(try await r.reportNow(reason: .wake) == nil)
        #expect(await sync.calls.isEmpty)
    }

    // MARK: R6f heartbeat, R9 (AC5)

    @Test func AC5_oneHeartbeatAfter30QuietMinutes() async {
        let reader = FixedBatteryReader(reading(80, .full))
        let r = await started(reader)
        #expect(clock.requests.last?.duration == .seconds(1800))
        #expect(clock.requests.last?.tolerance == .seconds(300))
        clock.advance(by: .seconds(29 * 60))
        await settle()
        #expect(await sync.reasons == [.launch])
        clock.advance(by: .seconds(60))
        await waitFor { [sync] in await sync.calls.count == 2 }
        await settle()
        #expect(await sync.reasons == [.launch, .heartbeat])
        await waitFor { [clock] in clock.requests.count == 2 && clock.sleeperCount == 1 }  // re-armed
        clock.advance(by: .seconds(30 * 60))
        await waitFor { [sync] in await sync.calls.count == 3 }
        #expect(await sync.reasons == [.launch, .heartbeat, .heartbeat])
        await r.stop()
    }

    @Test func R6f_heartbeatRestartsAfterAnAcceptedWrite() async {
        let reader = FixedBatteryReader(reading(80))
        let r = await started(reader)
        clock.advance(by: .seconds(20 * 60))
        reader.emit(reading(79))
        await waitFor { [sync] in await sync.calls.count == 2 }
        await waitFor { [clock] in clock.requests.count == 2 && clock.sleeperCount == 1 }  // re-armed
        clock.advance(by: .seconds(10 * 60))   // 30 min after launch, 10 after the change
        await settle()
        #expect(await sync.reasons == [.launch, .batteryChange])
        clock.advance(by: .seconds(20 * 60))   // 30 min after the change
        await waitFor { [sync] in await sync.calls.count == 3 }
        #expect(await sync.reasons.last == .heartbeat)
        await r.stop()
    }

    @Test func R6f_heartbeatKeepsItsScheduleWhenSyncHolds() async {
        await sync.set(outcome: .skipped)
        let reader = FixedBatteryReader(reading(80))
        let r = await started(reader)
        clock.advance(by: .seconds(20 * 60))
        reader.emit(reading(79))               // skipped by sync: heartbeat not moved
        await waitFor { [sync] in await sync.calls.count == 2 }
        clock.advance(by: .seconds(10 * 60))
        await waitFor { [sync] in await sync.calls.count == 3 }
        #expect(await sync.reasons.last == .heartbeat)
        await r.stop()
    }

    @Test func R9_readsOnlyOnTriggers() async {
        let reader = FixedBatteryReader(reading(80))
        let r = await started(reader)
        clock.advance(by: .seconds(29 * 60))
        await settle()
        #expect(reader.readCount == 1)
        #expect(clock.sleeperCount == 1)  // only the heartbeat timer
        await r.stop()
    }

    @Test func stopCancelsHeartbeatAndChanges() async {
        let reader = FixedBatteryReader(reading(80))
        let r = await started(reader)
        await r.stop()
        await waitFor { [clock] in clock.sleeperCount == 0 }
        clock.advance(by: .seconds(3600))
        reader.emit(reading(10))
        await settle()
        #expect(await sync.reasons == [.launch])
    }

    // MARK: RPT-001 shape (shared BatteryReporter)

    @Test func RPT001_AC4_failedOutcomeThrowsAndLeavesLog() async {
        await sync.set(outcome: .failed(retryAt: nil))
        let r = reporter(FixedBatteryReader(reading(50)))
        await #expect(throws: ReportError.syncFailed) { try await r.reportNow(reason: .wake) }
        #expect(log.all().isEmpty)
    }

    @Test func RPT001_AC4_signedOutThrowsICloudUnavailable() async {
        await sync.set(status: .signedOut)
        let r = reporter(FixedBatteryReader(reading(50)))
        await #expect(throws: ReportError.iCloudUnavailable) { try await r.reportNow(reason: .wake) }
        #expect(await sync.calls.count == 1)  // the reading still reached sync (cache)
    }

    @Test func RPT001_AC5_logRecordsReasonTime() async throws {
        let r = reporter(FixedBatteryReader(reading(50)))
        clock.advance(by: .seconds(42))
        let sent = try await r.reportNow(reason: .heartbeat)
        #expect(sent?.level == 50)
        #expect(log.lastReport(.heartbeat) == clock.date)
        #expect(log.lastReport(.wake) == nil)
    }

    @Test func RPT001_AC6_concurrentReportsDoNotOverlap() async {
        await sync.set(yields: 20)
        let r = reporter(FixedBatteryReader(reading(50)))
        async let a: ReportOutcome? = r.report(reason: .wake)
        async let b: ReportOutcome? = r.report(reason: .userRefresh)
        _ = await (a, b)
        #expect(await sync.calls.count == 2)
        #expect(await sync.maxInFlight == 1)
    }

    @Test func reportLogPersistsInUserDefaultsSuite() {
        let suite = "levels.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let at = Date(timeIntervalSince1970: 1_800_000_123)
        ReportLog(suiteName: suite).record(.appIntent, at: at)
        #expect(ReportLog(suiteName: suite).lastReport(.appIntent) == at)
        #expect(UserDefaults(suiteName: suite)?.dictionary(forKey: ReportLog.key)?["appIntent"] as? Date == at)
    }
}
