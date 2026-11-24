import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

/// The fresh read the hub sync sends before a fetch, mapped as a report maps it.
@Suite("BatteryReporter.recordSource")
struct RecordSourceTests {
    let id = DeviceID(UUID(uuidString: "11111111-2222-3333-4444-5555555555F0")!)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mapsLikeAReport() async {
        let prefs = InMemoryDisplayPreferencesStore()
        var p = prefs.load()
        p.thisDeviceName = "Tornike's phone"
        prefs.save(p)
        let reader = FixedBatteryReader(BatteryReading(level: 59, powerState: .charging, isLowPowerMode: true, readAt: t0))
        let record = await BatteryReporter.recordSource(reader: reader, kind: .iphone, identity: FixedDeviceIdentity(id),
                                                        preferences: prefs)()
        #expect(record == DeviceBattery(id: id, name: "Tornike's phone", kind: .iphone, level: 59, isCharging: true,
                                        isPluggedIn: true, isLowPowerMode: true, updatedAt: t0))
    }

    @Test func nilOnReadFailureOrNoID() async {
        let failed = FixedBatteryReader(BatteryReading(level: nil, powerState: .unknown, isLowPowerMode: false, readAt: t0))
        #expect(await BatteryReporter.recordSource(reader: failed, kind: .iphone, identity: FixedDeviceIdentity(id),
                                                   preferences: InMemoryDisplayPreferencesStore())() == nil)
        let noLevel = FixedBatteryReader(BatteryReading(level: nil, powerState: .charging, isLowPowerMode: false, readAt: t0))
        #expect(await BatteryReporter.recordSource(reader: noLevel, kind: .iphone, identity: FixedDeviceIdentity(id),
                                                   preferences: InMemoryDisplayPreferencesStore())() == nil)
        let good = FixedBatteryReader(BatteryReading(level: 50, powerState: .unplugged, isLowPowerMode: false, readAt: t0))
        #expect(await BatteryReporter.recordSource(reader: good, kind: .iphone, identity: FixedDeviceIdentity(nil),
                                                   preferences: InMemoryDisplayPreferencesStore())() == nil)
    }
}
