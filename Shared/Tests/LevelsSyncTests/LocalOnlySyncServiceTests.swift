import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsSync

private let macID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)

private func mac(level: Int? = 80, charging: Bool = false, pluggedIn: Bool? = false, lowPower: Bool = false,
                 name: String = "Office Mac", at: Date) -> DeviceBattery {
    DeviceBattery(id: macID, name: name, kind: .mac, level: level, isCharging: charging, isPluggedIn: pluggedIn,
                  isLowPowerMode: lowPower, updatedAt: at)
}

private func airpod(level: Int, at: Date) -> DeviceBattery {
    DeviceBattery(id: .accessory(key: "AA:BB:CC:DD:EE:FF", component: .left), name: "AirPods", kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: macID, kind: .airpods, groupID: UUID(), component: .left),
                  level: level, isCharging: false, updatedAt: at)
}

/// ADR-0008 as applied locally (see `LocalWritePolicy` docs). Pure.
@Suite("LOCAL LocalWritePolicy")
struct LocalWritePolicyTests {
    let policy = LocalWritePolicy()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func decide(_ new: DeviceBattery, _ reason: ReportReason, last: DeviceBattery?, ago: TimeInterval?) -> LocalWritePolicy.Decision {
        policy.decide(new: new, reason: reason, lastWritten: last, lastWriteAt: ago.map { t0 - $0 }, now: t0)
    }

    @Test func W1_noLastWriteWritesNow() {
        #expect(decide(mac(at: t0), .foreground, last: nil, ago: nil) == .writeNow)
    }

    @Test func W9_urgentUnchangedWritesNowOutsideFloor() {
        for reason in ReportReason.allCases where reason.isUrgent && reason != .chargerChange {
            #expect(decide(mac(at: t0), reason, last: mac(at: t0 - 20), ago: 20) == .writeNow, "\(reason)")
        }
    }

    @Test func W9_urgentInsideFloorIsHeldToFloor() {
        #expect(decide(mac(at: t0), .wake, last: mac(at: t0 - 4), ago: 4) == .writeAt(t0 + 6))
    }

    @Test func W7_nonUrgentUnchangedIsSkipped() {
        for reason in ReportReason.allCases where !reason.isUrgent {
            #expect(decide(mac(at: t0), reason, last: mac(at: t0 - 20 * 60), ago: 20 * 60) == .skip, "\(reason)")
        }
    }

    @Test func W2_chargerChangeWaitsForDebounceIgnoringMinInterval() {
        let new = mac(charging: true, pluggedIn: true, at: t0)
        #expect(decide(new, .chargerChange, last: mac(at: t0 - 20), ago: 20) == .writeAt(t0 + 3))
        #expect(decide(new, .batteryChange, last: mac(at: t0 - 20), ago: 20) == .writeAt(t0 + 3))
        #expect(decide(new, .chargerChange, last: mac(at: t0 - 1), ago: 1) == .writeAt(t0 + 9))  // floor wins
    }

    @Test func W3_lowPowerModeChangeWaitsForDebounce() {
        #expect(decide(mac(lowPower: true, at: t0), .batteryChange, last: mac(at: t0 - 20), ago: 20) == .writeAt(t0 + 3))
    }

    @Test func W4_local_anyLevelChangeWaitsForMinInterval() {
        #expect(decide(mac(level: 79, at: t0), .batteryChange, last: mac(at: t0 - 20), ago: 20) == .writeAt(t0 + 40))
        #expect(decide(mac(level: 79, at: t0), .batteryChange, last: mac(at: t0 - 61), ago: 61) == .writeNow)
    }

    @Test func W8_nameChangeWaitsForMinInterval() {
        #expect(decide(mac(name: "Renamed", at: t0), .foreground, last: mac(at: t0 - 30), ago: 30) == .writeAt(t0 + 30))
    }

    @Test func W6_heartbeatWritesWhenLastWriteIs30MinOld() {
        #expect(decide(mac(at: t0), .heartbeat, last: mac(at: t0 - 1799), ago: 1799) == .skip)
        #expect(decide(mac(at: t0), .heartbeat, last: mac(at: t0 - 1800), ago: 1800) == .writeNow)
    }
}

/// Counts widget reload requests.
final class ReloadCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func hit() { count.withLock { $0 += 1 } }
}

@Suite("LOCAL LocalOnlySyncService")
struct LocalOnlySyncServiceTests {
    let clock = ManualClock()
    let reloads = ReloadCounter()
    let reporting = ReportingSetting.inMemory()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levels-local-\(UUID().uuidString)")
    var cache: SnapshotCache { SnapshotCache(directory: directory) }

    func service() -> LocalOnlySyncService {
        let clock = clock, reloads = reloads
        return LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: { reloads.hit() },
                                    now: { clock.date }, clock: clock)
    }

    func cachedMac() -> DeviceBattery? { cache.read()?.devices.first { $0.id == macID } }

    func advance(_ seconds: Int) { clock.advance(by: .seconds(seconds)) }

    @Test func LOCAL_statusIsLocalOnly() async {
        let s = service()
        #expect(await s.status == .localOnly)
        await s.start()
        #expect(cache.read()?.syncStatus == .localOnly)
    }

    @Test func LOCAL_R5_firstReportWritesCacheAndReloadsWidgets() async {
        let s = service()
        let reading = mac(level: 66, charging: true, pluggedIn: true, at: clock.date)
        #expect(await s.report([reading], reason: .launch) == .uploaded)
        let file = cache.read()
        #expect(file?.devices == [reading])
        #expect(file?.ownDeviceID == macID)
        #expect(file?.lastWritten.isEmpty == true)  // "accepted by the server" stays SYNC-001's
        #expect(reloads.value == 1)
    }

    @Test func LOCAL_AC6a_urgencyAndFloor() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(20)
        let wake = mac(at: clock.date)
        #expect(await s.report([wake], reason: .wake) == .uploaded)
        #expect(cachedMac()?.updatedAt == wake.updatedAt)

        advance(4)
        let early = mac(at: clock.date)
        let heldUntil = clock.date + 6
        #expect(await s.report([early], reason: .userRefresh) == .held(until: heldUntil))
        #expect(cachedMac()?.updatedAt == wake.updatedAt)
        advance(6)
        await waitFor { [self] in cachedMac()?.updatedAt == early.updatedAt }

        advance(20)
        #expect(await s.report([mac(at: clock.date)], reason: .foreground) == .skipped)
        #expect(await s.report([mac(at: clock.date)], reason: .pushWake) == .skipped)
        #expect(cachedMac()?.updatedAt == early.updatedAt)
    }

    @Test func LOCAL_AC5_levelChangeHeldToMinIntervalLatestWins() async {
        let s = service()
        let t0 = clock.date
        _ = await s.report([mac(level: 80, at: t0)], reason: .launch)
        advance(20)
        #expect(await s.report([mac(level: 79, at: clock.date)], reason: .batteryChange) == .held(until: t0 + 60))
        advance(10)
        let latest = mac(level: 74, at: clock.date)
        #expect(await s.report([latest], reason: .batteryChange) == .held(until: t0 + 60))
        advance(29)
        await settle()
        #expect(cachedMac()?.level == 80)
        advance(1)
        await waitFor { [self] in cachedMac()?.level == 74 }
        #expect(cachedMac() == latest)
    }

    @Test func LOCAL_AC6_chargerFlipWithinDebounceIsOneWriteWithFinalState() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(20)
        _ = await s.report([mac(charging: true, pluggedIn: true, at: clock.date)], reason: .chargerChange)
        advance(2)
        let final = mac(charging: false, pluggedIn: false, at: clock.date)
        _ = await s.report([final], reason: .chargerChange)
        #expect(cachedMac()?.isCharging == false)
        #expect(cachedMac()?.updatedAt != final.updatedAt)
        advance(1)  // 3 s after the first flip
        await waitFor { [self] in cachedMac()?.updatedAt == final.updatedAt }
        advance(10)
        await settle()
        #expect(cachedMac() == final)
        #expect(reloads.value == 1)
        advance(60)
        await settle()
        // Lead's call 17: the final state equals what widgets have and the stale moment is
        // an hour away, so the write requests no reload at all.
        #expect(reloads.value == 1)
    }

    @Test func LOCAL_W6_heartbeatRefreshesUpdatedAtAfter30Min() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(29 * 60)
        #expect(await s.report([mac(at: clock.date)], reason: .heartbeat) == .skipped)
        advance(60)
        let beat = mac(at: clock.date)
        #expect(await s.report([beat], reason: .heartbeat) == .uploaded)
        #expect(cachedMac()?.updatedAt == beat.updatedAt)
    }

    @Test func LOCAL_AC9a_widgetReloadsCoalescedTo60s() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        #expect(reloads.value == 1)
        advance(10)
        _ = await s.report([mac(level: 79, at: clock.date)], reason: .wake)   // a shown change
        _ = await s.report([mac(level: 78, at: clock.date)], reason: .sleep)  // inside the floor: held
        #expect(reloads.value == 1)
        advance(49)
        await settle()
        #expect(reloads.value == 1)
        advance(1)                                                      // 60 s after the first reload
        await waitFor { [reloads] in reloads.value == 2 }
        advance(120)
        await settle()
        #expect(reloads.value == 2)                                     // exactly one trailing reload
    }

    /// Lead's call 17: a heartbeat that only moves `updatedAt` reloads only once the stale
    /// moment widgets have (65 min for a Mac) is less than 35 min away.
    @Test func LOCAL_R8a_heartbeatReloadsOnlyNearTheReceivedStaleMoment() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)        // widgets: stale at +65 min
        #expect(reloads.value == 1)
        advance(30 * 60)
        #expect(await s.report([mac(at: clock.date)], reason: .heartbeat) == .uploaded)  // 35 min away
        await settle()
        #expect(reloads.value == 1)
        advance(30 * 60)
        #expect(await s.report([mac(at: clock.date)], reason: .heartbeat) == .uploaded)  // 5 min away
        #expect(reloads.value == 2)
        advance(30 * 60)
        _ = await s.report([mac(at: clock.date)], reason: .heartbeat)   // judged against the new stale moment
        await settle()
        #expect(reloads.value == 2)
    }

    @Test func LOCAL_R8a_updatedAtOnlyChangeFarFromStaleRequestsNoReload() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(120)
        #expect(await s.report([mac(at: clock.date)], reason: .userRefresh) == .uploaded)  // moves updatedAt
        advance(120)
        await settle()
        #expect(reloads.value == 1)
        #expect(cachedMac()?.updatedAt == clock.date - 120)
    }

    @Test(arguments: [
        mac(level: 70, at: .distantPast), mac(charging: true, pluggedIn: true, at: .distantPast),
        mac(pluggedIn: true, at: .distantPast), mac(lowPower: true, at: .distantPast),
        mac(name: "Renamed", at: .distantPast),
    ])
    func LOCAL_R8a_shownFieldChangesReload(changed: DeviceBattery) async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(120)
        var next = changed
        next.updatedAt = clock.date
        _ = await s.report([next], reason: .userRefresh)
        advance(3)  // charger and Low Power Mode changes wait for the debounce
        await waitFor { [reloads] in reloads.value == 2 }  // outside the 60 s window: at once
        #expect(cachedMac() == next)
    }

    @Test func LOCAL_R8a_addedDeviceReloads() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(120)
        _ = await s.report([mac(at: clock.date - 120), airpod(level: 50, at: clock.date)], reason: .batteryChange)
        #expect(reloads.value == 2)
    }

    @Test func LOCAL_R8a_hiddenSetChangeReloadsCoalesced() async {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        advance(120)
        await s.displayPreferencesChanged()
        #expect(reloads.value == 2)
        await s.displayPreferencesChanged()   // inside 60 s: one trailing reload
        #expect(reloads.value == 2)
        advance(60)
        await waitFor { [reloads] in reloads.value == 3 }
    }

    // MARK: SYNC-001 R15a

    @Test func LOCAL_R15a_removeAllDataResetsDropsHeldWritesReloadsAndStopsReporting() async throws {
        let s = service()
        let t0 = clock.date
        _ = await s.report([mac(level: 80, at: t0)], reason: .launch)
        advance(20)
        #expect(await s.report([mac(level: 70, at: clock.date)], reason: .batteryChange) == .held(until: t0 + 60))
        try await s.removeAllData()
        #expect(cache.read() == nil)
        #expect(!reporting.isEnabled)

        advance(40)  // the held level-70 write was due now; the trailing reload fires
        await waitFor { [reloads] in reloads.value == 2 }  // widgets learn the cache is empty
        await settle()
        #expect(cache.read() == nil)
        #expect(await s.report([mac(at: clock.date)], reason: .userRefresh) == .skipped)
        #expect(cache.read() == nil)

        await s.resumeReporting()
        #expect(reporting.isEnabled)
        let back = mac(level: 60, at: clock.date)
        #expect(await s.report([back], reason: .launch) == .uploaded)  // W1: nothing written
        #expect(cache.read()?.devices == [back])
    }

    @Test func LOCAL_R15a_startWhileOffDoesNotRecreateTheCache() async throws {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        try await s.removeAllData()
        let relaunched = service()  // same setting, now off: a relaunch after removal
        await relaunched.start()
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path))
        #expect(await relaunched.report([mac(at: clock.date)], reason: .launch) == .skipped)
        #expect(cache.read() == nil)
    }

    @Test func LOCAL_R15a_removalWaitsForAReportInProgress() async throws {
        let s = service()
        async let first = s.report([mac(at: clock.date)], reason: .launch)
        async let removal: Void = s.removeAllData()
        _ = await first
        try await removal
        // Whichever ran first, the report did not land after the reset.
        #expect(cache.read() == nil)
    }

    @Test func LOCAL_R15a_failedResetChangesNothing() async throws {
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        // A read-only parent directory makes the delete fail.
        let parent = cache.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        await #expect(throws: (any Error).self) { try await s.removeAllData() }
        #expect(reporting.isEnabled)
        #expect(cachedMac() != nil)
    }

    @Test func LOCAL_AC9a_unchangedDevicesRequestNoReload() async {
        let s = service()
        let reading = mac(at: clock.date)
        _ = await s.report([reading], reason: .launch)
        advance(120)
        #expect(await s.report([reading], reason: .userRefresh) == .uploaded)  // same values and updatedAt
        await settle()
        #expect(reloads.value == 1)
    }

    @Test func LOCAL_ownAndAccessoryInOneWriteJudgedPerRecord() async {
        let s = service()
        let t0 = clock.date
        #expect(await s.report([mac(at: t0), airpod(level: 50, at: t0)], reason: .launch) == .uploaded)
        #expect(cache.read()?.devices.count == 2)
        #expect(cache.read()?.ownDeviceID == macID)
        advance(20)
        // Mac unchanged (skip), AirPod level changed (held to the 60 s gap).
        #expect(await s.report([mac(at: clock.date), airpod(level: 45, at: clock.date)], reason: .batteryChange) == .held(until: t0 + 60))
        advance(40)
        await waitFor { [self] in cache.read()?.devices.first { $0.kind == .accessory }?.level == 45 }
        #expect(cachedMac()?.updatedAt == t0)
    }

    /// MAC-003: the accessory reporter sends accessories on their own. That must not change
    /// `ownDeviceID`, and a later Mac-only report (accessory disconnected) keeps the accessory
    /// record with its last level and `updatedAt` (R4).
    @Test func MAC003_accessoryOnlyReportsKeepOwnIDAndDisconnectKeepsLastValue() async {
        let s = service()
        let t0 = clock.date
        _ = await s.report([mac(at: t0)], reason: .launch)
        #expect(await s.report([airpod(level: 40, at: t0)], reason: .launch) == .uploaded)
        #expect(cache.read()?.ownDeviceID == macID)
        advance(120)
        _ = await s.report([mac(level: 79, at: clock.date)], reason: .batteryChange)
        let pod = cache.read()?.devices.first { $0.kind == .accessory }
        #expect(pod?.level == 40)
        #expect(pod?.updatedAt == t0)
        #expect(pod?.accessory?.parentDeviceID == macID)
    }

    @Test func LOCAL_keepsOtherDevicesInTheCache() async throws {
        let phone = DeviceBattery(id: DeviceID(UUID()), name: "iPhone", kind: .iphone, level: 30, isCharging: false,
                                  updatedAt: clock.date - 600)
        try cache.update { $0.devices = [phone] }
        let s = service()
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        #expect(Set(cache.read()?.devices.map(\.id) ?? []) == [phone.id, macID])
    }

    @Test func LOCAL_failedCacheWriteReturnsFailedAndRetriesOnNextTrigger() async throws {
        // A newer format makes `update` refuse to write (SYNC-002).
        let url = cache.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"formatVersion": 99}"#.utf8).write(to: url)
        let s = service()
        #expect(await s.report([mac(at: clock.date)], reason: .launch) == .failed(retryAt: nil))
        #expect(reloads.value == 0)
        try FileManager.default.removeItem(at: url)
        advance(1)
        let next = mac(at: clock.date)
        #expect(await s.report([next], reason: .foreground) == .uploaded)  // still W1: nothing was written
        #expect(cachedMac() == next)
    }

    @Test func LOCAL_refreshReloadsCache() async {
        let s = service()
        #expect(await s.refresh(.userPull) == false)  // no file yet
        _ = await s.report([mac(at: clock.date)], reason: .launch)
        #expect(await s.refresh(.userPull))
    }

    @Test func LOCAL_usableThroughTheBatterySyncingSeam() async {
        let sync: any BatterySyncing = service()
        #expect(await sync.report([mac(at: clock.date)], reason: .launch) == .uploaded)
        #expect(await sync.status == .localOnly)
        #expect(await sync.refresh(.wake))  // through the protocol, not the concrete type
    }
}
