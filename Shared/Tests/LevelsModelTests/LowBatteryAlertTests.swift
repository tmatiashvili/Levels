import Foundation
import Testing
@testable import LevelsModel

// ALR-001 AC1–AC9.

private let mac = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
private let mouseID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
private let podsGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!

private func ownMac(level: Int = 5) -> DeviceBattery {
    DeviceBattery(id: mac, name: "MacBook", kind: .mac, level: level, isCharging: false, updatedAt: now)
}

private func mouse(_ level: Int?, charging: Bool = false, at date: Date = now) -> DeviceBattery {
    DeviceBattery(id: mouseID, name: "Magic Mouse", kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: mac, kind: .mouse, groupID: UUID(), component: .main),
                  level: level, isCharging: charging, updatedAt: date)
}

private func pod(_ component: AccessoryComponent, _ level: Int?, charging: Bool = false, at date: Date = now) -> DeviceBattery {
    DeviceBattery(id: DeviceID.accessory(key: "AA:BB", component: component), name: "TPods", kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: mac, kind: .airpods, groupID: podsGroup, component: component),
                  level: level, isCharging: charging, updatedAt: date)
}

private func snapshot(_ devices: [DeviceBattery]) -> SnapshotFile {
    SnapshotFile(ownDeviceID: mac, devices: [ownMac()] + devices)
}

/// Runs the rule over a sequence of snapshots, carrying the state like the app does.
private func run(_ steps: [[DeviceBattery]], settings: AlertSettings = .init(isEnabled: true),
                 state: AlertState = AlertState(), hidden: Set<DeviceID> = [],
                 reporting: Bool = true) -> (alerts: [LowBatteryAlert], state: AlertState) {
    var state = state
    var all: [LowBatteryAlert] = []
    for devices in steps {
        let subjects = LowBatteryAlertRule.subjects(in: snapshot(devices), hidden: hidden, now: now)
        let r = LowBatteryAlertRule.evaluate(subjects, settings: settings, state: state, reportingEnabled: reporting, now: now)
        all += r.alerts
        state = r.state
    }
    return (all, state)
}

@Suite("ALR-001 low-battery alerts")
struct LowBatteryAlertTests {
    @Test("AC1: one alert per discharge cycle, at the first low reading")
    func oneAlertPerCycle() {
        let r = run([30, 25, 19, 15, 5].map { [mouse($0)] })
        #expect(r.alerts.map(\.level) == [19])
        #expect(r.alerts.first?.text == "Magic Mouse is at 19%")
    }

    @Test("AC1: the threshold itself is low; 21 is not")
    func thresholdIsInclusive() {
        #expect(run([[mouse(21)]]).alerts.isEmpty)
        #expect(run([[mouse(20)]]).alerts.count == 1)
    }

    @Test("AC2: charging re-arms")
    func chargingRearms() {
        let r = run([[mouse(15)], [mouse(16, charging: true)], [mouse(14)]])
        #expect(r.alerts.map(\.level) == [15, 14])
    }

    @Test("AC2: threshold + 10 re-arms, below it does not")
    func marginRearms() {
        #expect(run([[mouse(15)], [mouse(30)], [mouse(12)]]).alerts.count == 2)
        #expect(run([[mouse(15)], [mouse(25)], [mouse(12)]]).alerts.count == 1)
    }

    @Test("AC2: charging while low gives no alert")
    func chargingNeverAlerts() {
        #expect(run([[mouse(5, charging: true)]]).alerts.isEmpty)
    }

    @Test("AC3: never about this Mac")
    func neverAboutItself() {
        #expect(run([[]]).alerts.isEmpty)  // the snapshot holds this Mac at 5 %
        let subjects = LowBatteryAlertRule.subjects(in: snapshot([mouse(50)]), now: now)
        #expect(subjects.map(\.rowID) == [mouseID])
        let hidden = LowBatteryAlertRule.subjects(in: snapshot([mouse(50)]), hidden: [mouseID], now: now)
        #expect(hidden.map(\.isHidden) == [true])
    }

    @Test("AC3: hidden devices don't alert, by record or by group ID")
    func hiddenDontAlert() {
        #expect(run([[mouse(5)]], hidden: [mouseID]).alerts.isEmpty)
        #expect(run([[pod(.left, 5), pod(.right, 5)]], hidden: [DeviceID(podsGroup)]).alerts.isEmpty)
    }

    @Test("AC4: AirPods earbuds are one subject at the lower bud; the case is separate")
    func airPodsSubjects() {
        let r = run([[pod(.left, 15), pod(.right, 18), pod(.case, 60)]])
        #expect(r.alerts.count == 1)
        #expect(r.alerts.first?.part == .earbuds)
        #expect(r.alerts.first?.level == 15)
        #expect(r.alerts.first?.text == "TPods is at 15%")
        #expect(r.alerts.first?.rowID == DeviceID(podsGroup))

        let both = run([[pod(.left, 15), pod(.right, 18), pod(.case, 10)]])
        #expect(both.alerts.map(\.text).sorted() == ["TPods case is at 10%", "TPods is at 15%"])
    }

    @Test("AC4: buds charging in the case re-arm the earbuds only")
    func budsInCase() {
        let r = run([
            [pod(.left, 15), pod(.right, 15), pod(.case, 10)],
            [pod(.left, 16, charging: true), pod(.right, 16, charging: true), pod(.case, 9)],
            [pod(.left, 14), pod(.right, 14), pod(.case, 8)],
        ])
        #expect(r.alerts.map(\.part) == [.earbuds, .case, .earbuds])
    }

    @Test("AC4a: a bud read hours ago doesn't hide the live bud or block re-arming")
    func staleBudIgnored() {
        let old = now.addingTimeInterval(-3 * hour)
        let r = run([
            [pod(.left, 5, at: old), pod(.right, 15)],
            [pod(.left, 5, at: old), pod(.right, 16, charging: true)],
            [pod(.left, 5, at: old), pod(.right, 12)],
        ])
        #expect(r.alerts.map(\.level) == [15, 12])
    }

    @Test("AC4a: with no fresh bud, the earbuds are too old to alert")
    func allBudsStale() {
        let old = now.addingTimeInterval(-3 * hour)
        #expect(run([[pod(.left, 5, at: old), pod(.right, 6, at: old)]]).alerts.isEmpty)
    }

    @Test("AC3: hide then unhide while low doesn't repeat the alert")
    func hideUnhide() {
        let first = run([[mouse(15)]])
        #expect(first.alerts.count == 1)
        let hidden = run([[mouse(14)]], state: first.state, hidden: [mouseID])
        #expect(hidden.alerts.isEmpty)
        #expect(hidden.state == first.state)
        #expect(run([[mouse(13)]], state: hidden.state).alerts.isEmpty)
    }

    @Test("AC3: a hidden device still re-arms on charging")
    func hiddenRearms() {
        let first = run([[mouse(15)]])
        let charged = run([[mouse(40, charging: true)]], state: first.state, hidden: [mouseID])
        #expect(charged.state.disarmed.isEmpty)
    }

    @Test("AC6: forgetDevices empties the per-device switches only")
    func forgetDevices() {
        var s = AlertSettings(isEnabled: false, threshold: 35, mutedDevices: [mouseID, DeviceID(podsGroup)])
        s.forgetDevices()
        #expect(s == AlertSettings(isEnabled: false, threshold: 35))
    }

    @Test("AC4: one bud connected uses that bud")
    func oneBud() {
        #expect(run([[pod(.right, 10)]]).alerts.map(\.level) == [10])
    }

    @Test("AC5: alerts off or device muted posts nothing; charging still re-arms")
    func offAndMuted() {
        #expect(run([[mouse(5)]], settings: .init(isEnabled: false)).alerts.isEmpty)
        #expect(run([[mouse(5)]], settings: .init(isEnabled: true, mutedDevices: [mouseID])).alerts.isEmpty)
        #expect(run([[pod(.left, 5)]], settings: .init(isEnabled: true, mutedDevices: [DeviceID(podsGroup)])).alerts.isEmpty)

        // Alerted, then alerts off, charged meanwhile: re-armed, so turning on alerts again.
        let first = run([[mouse(15)]])
        let off = run([[mouse(50, charging: true)]], settings: .init(isEnabled: false), state: first.state)
        #expect(off.state.disarmed.isEmpty)
        #expect(run([[mouse(10)]], state: off.state).alerts.count == 1)
    }

    @Test("AC5: a low device stays armed while muted, then alerts once when turned on")
    func turnOnWhileLow() {
        let muted = run([[mouse(10)]], settings: .init(isEnabled: false))
        #expect(muted.state.disarmed.isEmpty)
        #expect(run([[mouse(10)], [mouse(9)]], state: muted.state).alerts.count == 1)
    }

    @Test("AC6: reporting off posts nothing and clears the state")
    func reportingOff() {
        let first = run([[mouse(15)]])
        #expect(!first.state.disarmed.isEmpty)
        let r = run([[mouse(5)]], state: first.state, reporting: false)
        #expect(r.alerts.isEmpty)
        #expect(r.state == AlertState())
    }

    @Test("AC7: readings older than 1 hour change nothing")
    func lateReadings() {
        let old = mouse(5, at: now.addingTimeInterval(-hour - minute))
        let r = run([[old]])
        #expect(r.alerts.isEmpty)
        #expect(r.state.disarmed.isEmpty)
        #expect(run([[mouse(5, at: now.addingTimeInterval(-hour + minute))]]).alerts.count == 1)

        let disarmed = run([[mouse(15)]]).state
        let lateCharge = run([[mouse(80, charging: true, at: now.addingTimeInterval(-2 * hour))]], state: disarmed)
        #expect(lateCharge.state == disarmed)
    }

    @Test("AC8: saved state survives a relaunch; no repeat")
    func persistence() throws {
        let suite = "alr-001-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAlertStore(suiteName: suite)
        #expect(store.loadState() == AlertState())
        #expect(store.loadSettings(defaults: .defaults(for: .mac)) == AlertSettings(isEnabled: true))

        let first = run([[mouse(15)]])
        #expect(first.alerts.count == 1)
        store.saveState(first.state)
        store.saveSettings(AlertSettings(isEnabled: true, threshold: 30, mutedDevices: [mouseID]))

        let relaunched = UserDefaultsAlertStore(suiteName: suite)
        #expect(run([[mouse(15)]], state: relaunched.loadState()).alerts.isEmpty)
        let s = relaunched.loadSettings(defaults: .defaults(for: .mac))
        #expect(s.threshold == 30)
        #expect(s.mutedDevices == [mouseID])
    }

    @Test("AC8: removed devices are pruned from the state")
    func pruning() {
        let first = run([[mouse(15)]])
        #expect(run([[]], state: first.state).state.disarmed.isEmpty)
    }

    @Test("AC9: defaults follow owner decision H")
    func defaults() {
        #expect(AlertSettings.defaultEnabled(for: .mac))
        #expect(AlertSettings.defaultEnabled(for: .ipad))
        #expect(!AlertSettings.defaultEnabled(for: .iphone))
        #expect(!AlertSettings.defaultEnabled(for: .watch))
        #expect(AlertSettings.defaults(for: .mac).threshold == 20)
        #expect(AlertSettings.defaults(for: .mac).mutedDevices.isEmpty)
    }

    @Test("AC9: thresholds are clamped to 5–50 and rounded to steps of 5",
          arguments: [(0, 5), (3, 5), (5, 5), (12, 10), (13, 15), (20, 20), (49, 50), (80, 50)])
    func thresholdNormalised(input: Int, expected: Int) {
        #expect(AlertSettings(isEnabled: true, threshold: input).threshold == expected)
        var s = AlertSettings(isEnabled: true)
        s.threshold = input
        #expect(s.threshold == expected)
    }

    @Test("AC9: a raised threshold alerts at the new level")
    func customThreshold() {
        #expect(run([[mouse(28)]], settings: .init(isEnabled: true, threshold: 30)).alerts.count == 1)
    }

    @Test("AC9: identifier and tap URL")
    func identifierAndURL() throws {
        let alert = try #require(run([[mouse(10)]]).alerts.first)
        #expect(alert.identifier == "low-\(mouseID.recordName)")
        #expect(alert.url.absoluteString == "levels://device/\(mouseID.recordName)")
        #expect(LevelsAppConfig.route(alert.url) == .device(mouseID))

        let pods = try #require(run([[pod(.case, 10)]]).alerts.first)
        #expect(pods.identifier == "low-\(DeviceID(podsGroup).recordName):case")
        #expect(LevelsAppConfig.route(pods.url) == .device(DeviceID(podsGroup)))
    }

    @Test("No level never alerts")
    func noLevel() {
        #expect(run([[mouse(nil)]]).alerts.isEmpty)
    }

    @Test("Settings decode missing keys as defaults")
    func decodePartial() throws {
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"threshold":33}"#.utf8))
        #expect(s.isEnabled)
        #expect(s.threshold == 35)
        #expect(s.mutedDevices.isEmpty)
    }
}
