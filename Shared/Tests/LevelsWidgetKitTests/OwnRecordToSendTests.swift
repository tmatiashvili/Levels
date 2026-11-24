import Foundation
import LevelsModel
import Testing
@testable import LevelsWidgetKit

/// The iPhone widget sends the reading it reads itself (it used to only show it).
@Suite("iPhone widget: which own record goes to the Mac")
struct OwnRecordToSendTests {
    let me = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000F1")!)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func file(level: Int = 60, at: Date) -> SnapshotFile {
        SnapshotFile(ownDeviceID: me, devices: [DeviceBattery(id: me, name: "My iPhone", kind: .iphone, level: level,
                                                              isCharging: false, isPluggedIn: false, updatedAt: at)])
    }

    @Test func aNewerReadingIsLaidOverTheCachedRecord() {
        let reading = OwnBatteryReading(level: 59, state: .charging, isLowPowerMode: true, readAt: t0 + 600)
        let record = file(at: t0).ownRecordToSend(reading)
        #expect(record?.level == 59)
        #expect(record?.isCharging == true && record?.isPluggedIn == true && record?.isLowPowerMode == true)
        #expect(record?.name == "My iPhone" && record?.kind == .iphone && record?.updatedAt == t0 + 600)
    }

    @Test func nothingWithoutALevelANewerTimeOrAnOwnRecord() {
        #expect(file(at: t0).ownRecordToSend(OwnBatteryReading(level: nil, state: .unknown, isLowPowerMode: false,
                                                               readAt: t0 + 600)) == nil)
        #expect(file(at: t0).ownRecordToSend(OwnBatteryReading(level: 50, state: .unplugged, isLowPowerMode: false,
                                                               readAt: t0 - 1)) == nil)
        #expect(SnapshotFile(ownDeviceID: me).ownRecordToSend(OwnBatteryReading(level: 50, state: .unplugged,
                                                                                isLowPowerMode: false, readAt: t0)) == nil)
        #expect(file(at: t0).ownRecordToSend(nil) == nil)
    }
}
