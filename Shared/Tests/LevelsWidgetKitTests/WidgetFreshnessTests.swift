// Regression: "the widget is not updating the battery level" (2026-11-24). The app writes the
// iPhone's own record only while it runs; the widget's fetch from the Mac keeps that cached own
// record, so overnight the widget refreshed the Mac every 30 min but kept showing the iPhone's
// level from the app's last run. The widget now lays its own UIDevice reading over the record.
import Foundation
import LevelsModel
import Testing
import WidgetKit
@testable import LevelsWidgetKit

private let evening = Date(timeIntervalSince1970: 1_800_000_000)
private let morning = evening + 8 * 3600
private let phoneID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
private let macID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

private func phone(_ level: Int, at: Date, charging: Bool = false) -> DeviceBattery {
    DeviceBattery(id: phoneID, name: "iPhone", kind: .iphone, level: level, isCharging: charging,
                  isPluggedIn: charging, updatedAt: at)
}
private func mac(_ level: Int, at: Date) -> DeviceBattery {
    DeviceBattery(id: macID, name: "MacBook", kind: .mac, level: level, isCharging: false, updatedAt: at)
}
private func file(_ devices: [DeviceBattery], lastFetchAt: Date?) -> SnapshotFile {
    var f = SnapshotFile(ownDeviceID: phoneID, devices: devices)
    f.lastFetchAt = lastFetchAt
    f.syncStatus = .localOnly
    return f
}
private func reading(_ level: Int?, _ state: OwnBatteryReading.State = .unplugged, at: Date = morning) -> OwnBatteryReading {
    OwnBatteryReading(level: level, state: state, isLowPowerMode: false, readAt: at)
}

/// The widget's variant B fetch as on the device: the Mac's full snapshot merged into the cache,
/// own record kept (`WidgetHubFetch`).
private func macFetch(_ macNow: DeviceBattery, at t: Date) -> HubWidgetPlan.Fetch {
    { cached in
        var f = cached!
        f.merge(fetched: [macNow], isFullFetch: true, ownIDs: [phoneID])
        f.lastFetchAt = t
        return .fetched(f)
    }
}

@Suite("Widget freshness (own iPhone reading)")
struct WidgetFreshnessTests {
    private func level(_ timeline: Timeline<DeviceEntry>, _ id: DeviceID) -> Int? {
        timeline.entries.first?.rows.flatMap(\.records).first { $0.id == id }?.level
    }

    @Test func overnightFetchRefreshesTheMacButNotTheIPhoneWithoutAnOwnReading() async {
        // The app last ran in the evening (iPhone 80 %, Mac 90 %). In the morning the widget
        // reloads, the cache is old, the fetch from the Mac succeeds.
        let cached = file([phone(80, at: evening), mac(90, at: evening)], lastFetchAt: evening)
        let t = await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: morning,
                                                  selection: nil, fetch: macFetch(mac(55, at: morning - 60), at: morning),
                                                  own: nil)
        #expect(level(t, macID) == 55)
        #expect(level(t, phoneID) == 80)  // the bug: nothing but the app updates this record
    }

    @Test func ownReadingShowsTheLiveIPhoneLevel() async {
        let cached = file([phone(80, at: evening), mac(90, at: evening)], lastFetchAt: evening)
        let t = await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: morning,
                                                  selection: nil, fetch: macFetch(mac(55, at: morning - 60), at: morning),
                                                  own: reading(41))
        #expect(level(t, macID) == 55)
        #expect(level(t, phoneID) == 41)
        #expect(t.policy == .after(morning + HubWidgetPlan.afterSuccess))
    }

    @Test func ownReadingAlsoAppliesWhenTheMacIsAway() async {
        let cached = file([phone(80, at: evening), mac(90, at: evening)], lastFetchAt: evening)
        let t = await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: morning,
                                                  selection: nil, fetch: { _ in .failed }, own: reading(41))
        #expect(level(t, phoneID) == 41)
        #expect(level(t, macID) == 90)
        #expect(t.policy == .after(morning + HubWidgetPlan.afterFailure))  // last contact 8 h ago
        #expect(t.entries.first?.awayFooterDate != nil)
    }

    @Test func ownReadingAlsoAppliesWhileTheCacheIsFresh() async {
        let cached = file([phone(80, at: morning - 600), mac(90, at: morning - 600)], lastFetchAt: morning - 600)
        let t = await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: morning,
                                                  selection: nil, fetch: { _ in Issue.record("no fetch"); return .failed },
                                                  own: reading(77))
        #expect(level(t, phoneID) == 77)
        #expect(t.policy == .after(morning - 600 + HubWidgetPlan.afterSuccess))
    }

    // MARK: overlay rules

    @Test func overlayMapsChargingStatesLikeTheApp() {
        let f = file([phone(50, at: evening)], lastFetchAt: nil)
        let charging = f.overlaying(own: reading(51, .charging)).devices[0]
        #expect(charging.level == 51 && charging.isCharging && charging.isPluggedIn == true && charging.updatedAt == morning)
        let full = f.overlaying(own: reading(100, .full)).devices[0]
        #expect(!full.isCharging && full.isPluggedIn == true)
        let unplugged = file([phone(50, at: evening, charging: true)], lastFetchAt: nil).overlaying(own: reading(49)).devices[0]
        #expect(!unplugged.isCharging && unplugged.isPluggedIn == false)
        let unknown = file([phone(50, at: evening, charging: true)], lastFetchAt: nil)
            .overlaying(own: reading(49, .unknown)).devices[0]
        #expect(unknown.level == 49 && unknown.isCharging)  // unknown state keeps the record's flags
    }

    @Test func overlayIgnoresUnknownLevelOlderReadingAndMissingOwnRecord() {
        let f = file([phone(50, at: evening), mac(90, at: evening)], lastFetchAt: nil)
        #expect(f.overlaying(own: nil) == f)
        #expect(f.overlaying(own: reading(nil)) == f)  // UIDevice answered −1
        #expect(f.overlaying(own: reading(20, at: evening - 1)) == f)  // the app's record is newer
        var noOwn = f
        noOwn.ownDeviceID = nil
        #expect(noOwn.overlaying(own: reading(20)) == noOwn)
        var otherOwn = f
        otherOwn.ownDeviceID = DeviceID(UUID())
        #expect(otherOwn.overlaying(own: reading(20)) == otherOwn)
        #expect(f.overlaying(own: reading(20)).devices.first { $0.id == macID }?.level == 90)
    }

    @Test func levelFromFractionMatchesTheAppReader() {
        #expect(OwnBatteryReading.level(fromFraction: -1) == nil)
        #expect(OwnBatteryReading.level(fromFraction: .nan) == nil)
        #expect(OwnBatteryReading.level(fromFraction: 0.415) == 42)
        #expect(OwnBatteryReading.level(fromFraction: 1.2) == 100)
    }

    // MARK: reload schedule and timeline shape (2026-11-24: 90 min gaps in the hub log)

    @Test func missesRightAfterAGoodFetchRetrySoonThenBackOff() async {
        // 11:24 good fetch; the 11:54 reload misses the Mac. It used to retry at 12:54.
        let good = morning
        let cached = file([phone(80, at: good), mac(90, at: good)], lastFetchAt: good)
        var retries: [TimelineReloadPolicy] = []
        for minutes in [30.0, 45, 60, 90, 180] {
            let t = good + minutes * 60
            retries.append(await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: t,
                                                             selection: nil, fetch: { _ in .failed }, own: nil).policy)
        }
        #expect(retries == [.after(good + 45 * 60), .after(good + 60 * 60), .after(good + 90 * 60),
                            .after(good + 120 * 60), .after(good + 240 * 60)])
    }

    @Test func staleMomentsAfterTheReloadDateStayInTheTimeline() async {
        // WidgetKit often reloads later than asked. The Mac reading (65 min threshold) turns
        // stale 35 min after the 30 min reload date; that entry must still be there.
        let cached = file([phone(80, at: morning), mac(90, at: morning)], lastFetchAt: morning)
        let tl = await DevicesProvider.hubTimeline(cached: cached, preferences: DisplayPreferences(), now: morning,
                                                   selection: nil, fetch: { _ in Issue.record("no fetch"); return .failed },
                                                   own: nil)
        #expect(tl.policy == .after(morning + HubWidgetPlan.afterSuccess))
        let dates = tl.entries.map(\.date)
        #expect(dates.first == morning)
        #expect(dates.contains(morning + FreshnessRule.macThreshold))
        #expect(dates.contains(morning + FreshnessRule.handheldThreshold))
    }

    @Test func aFetchWithOlderDataNeverMovesALevelBack() {
        // The app's long-poll wrote the Mac at 40 % while the widget's request was in flight;
        // the widget's answer still says 55 % from earlier. The newer reading stays.
        var f = file([phone(80, at: morning), mac(40, at: morning)], lastFetchAt: morning + 30)
        f.mergeFetch([mac(55, at: morning - 300), phone(10, at: morning + 60)], ownID: phoneID, at: morning + 10)
        #expect(f.devices.first { $0.id == macID }?.level == 40)
        #expect(f.devices.first { $0.id == phoneID }?.level == 80)  // own record: the local copy wins
        #expect(f.lastFetchAt == morning + 30)                       // never moves back
        f.mergeFetch([mac(35, at: morning + 120)], ownID: phoneID, at: morning + 120)
        #expect(f.devices.first { $0.id == macID }?.level == 35)
        #expect(f.lastFetchAt == morning + 120)
        #expect(f.syncStatus == .localOnly)
    }
}

@Suite("Widget shared fetch")
struct SharedFetchTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() -> Int { lock.withLock { n += 1; return n } }
        var value: Int { lock.withLock { n } }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    @Test func concurrentCallersShareOneRun() async {
        let runs = Counter()
        let shared = SharedFetch<Int>(reuseFor: 60)
        let results = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await shared.run {
                        let n = runs.hit()
                        try? await Task.sleep(for: .milliseconds(200))
                        return n
                    }
                }
            }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(runs.value == 1)
        #expect(results == [1, 1, 1, 1, 1])
    }

    @Test func aResultIsReusedOnlyInsideTheWindow() async {
        let runs = Counter()
        let clock = Clock()
        let shared = SharedFetch<Int>(reuseFor: 60, now: { clock.now })
        #expect(await shared.run { runs.hit() } == 1)
        clock.advance(59)
        #expect(await shared.run { runs.hit() } == 1)
        clock.advance(2)
        #expect(await shared.run { runs.hit() } == 2)
        clock.advance(-3600)  // clock moved back: don't trust the old result
        #expect(await shared.run { runs.hit() } == 3)
    }
}
