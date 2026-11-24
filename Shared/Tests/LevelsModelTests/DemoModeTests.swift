import Foundation
import Testing
@testable import LevelsModel

@Suite("DEMO-001 sample devices and the demo flag")
struct DemoModeTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("AC2: ages are measured from now, so they look the same at any time")
    func ac2AgesAreLive() {
        let a = SampleDevices.snapshot(now: t0)
        let b = SampleDevices.snapshot(now: t0 + 5 * 86_400)
        #expect(a.devices.map { t0.timeIntervalSince($0.updatedAt) } == b.devices.map { (t0 + 5 * 86_400).timeIntervalSince($0.updatedAt) })
        #expect(a.devices.map(\.id) == b.devices.map(\.id))
    }

    @Test("AC2: the R2 set, generic names only")
    func ac2SampleSet() throws {
        let file = SampleDevices.snapshot(now: t0)
        #expect(file.ownDeviceID == SampleDevices.iPhoneID)
        #expect(file.syncStatus == .localOnly)
        #expect(Set(file.devices.map(\.name)) == ["iPhone", "MacBook Pro", "AirPods Pro", "Apple Watch", "iPad"])
        #expect(file.devices.allSatisfy { !$0.name.contains("’") && !$0.name.contains("'") })  // no possessive owner names
        #expect(file.devices.allSatisfy { $0.hasConsistentAccessory })

        let watch = try #require(file.devices.first { $0.id == SampleDevices.watchID })
        #expect(FreshnessRule.of(watch, at: t0) == .stale)
        let iPad = try #require(file.devices.first { $0.id == SampleDevices.iPadID })
        #expect(try #require(iPad.level) <= 20)
        for id in [SampleDevices.iPhoneID, SampleDevices.macID, SampleDevices.iPadID] {
            let d = try #require(file.devices.first { $0.id == id })
            #expect(FreshnessRule.of(d, at: t0) == .fresh)
        }

        let pods = file.devices.filter { $0.kind == .accessory }
        #expect(pods.map { $0.accessory?.component }.sorted { $0!.rawValue < $1!.rawValue } == [.case, .left, .right])
        #expect(pods.allSatisfy { $0.accessory?.parentDeviceID == SampleDevices.macID })
        #expect(pods.allSatisfy { $0.accessory?.groupID == SampleDevices.airPodsGroup })
        #expect(SampleDevices.isSample(file))
        #expect(!SampleDevices.isSample(SnapshotFile(ownDeviceID: DeviceID(UUID()))))
        #expect(!SampleDevices.isSample(nil))
    }

    @Test("In memory: off by default, then on and off")
    func inMemory() {
        let s = DemoModeSetting.inMemory()
        #expect(!s.isOn)
        s.setOn(true)
        #expect(s.isOn)
        s.setOn(false)
        #expect(!s.isOn)
    }

    @Test("AC5: the flag survives in the App Group defaults (relaunch, widget)")
    func ac5Persists() throws {
        let suite = "levels-demo-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(!DemoModeSetting(suiteName: suite).isOn)
        DemoModeSetting(suiteName: suite).setOn(true)
        #expect(DemoModeSetting(suiteName: suite).isOn)  // a new instance, like a relaunch or the widget
        #expect(try #require(UserDefaults(suiteName: suite)).bool(forKey: DemoModeSetting.key))
        DemoModeSetting(suiteName: suite).setOn(false)
        #expect(!DemoModeSetting(suiteName: suite).isOn)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: DemoModeSetting.key) == nil)
    }
}
