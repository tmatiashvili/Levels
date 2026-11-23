import Foundation
import Testing
@testable import LevelsModel

@Suite("Device model")
struct DeviceModelTests {
    @Test("R1: record name is lowercase; parsing accepts either case")
    func recordName() throws {
        let uuid = UUID(uuidString: "3F6A1C52-8E0B-4D8F-9B67-2C4E1A7D90B3")!
        let id = DeviceID(uuid)
        #expect(id.recordName == "3f6a1c52-8e0b-4d8f-9b67-2c4e1a7d90b3")
        #expect(DeviceID(recordName: id.recordName) == id)
        #expect(DeviceID(recordName: uuid.uuidString) == id)
        #expect(DeviceID(recordName: "abc") == nil)
    }

    @Test("AC8: accessory IDs are deterministic, per component, and pinned")
    func ac8AccessoryID() {
        let left1 = DeviceID.accessory(key: "AA:BB:CC:DD:EE:FF", component: .left)
        let left2 = DeviceID.accessory(key: "AA:BB:CC:DD:EE:FF", component: .left)
        let right = DeviceID.accessory(key: "AA:BB:CC:DD:EE:FF", component: .right)
        #expect(left1 == left2)
        #expect(left1 != right)
        // Golden values (Python uuid.uuid5 with the same namespace and name): equal on every machine.
        #expect(left1.recordName == "060fa350-0031-53ce-8273-1c941a6da860")
        #expect(right.recordName == "6a18f340-5410-525d-a425-619ff9a2db4b")
    }

    @Test("AC8: UUIDv5 matches the RFC 9562 test vector")
    func uuidV5Vector() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        #expect(UUID.v5(namespace: dns, name: "www.example.com").uuidString.lowercased()
                == "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    @Test("R3: the initializer clamps level to 0...100")
    func levelClamp() {
        #expect(battery(level: 140).level == 100)
        #expect(battery(level: -3).level == 0)
        #expect(battery(level: nil).level == nil)
        #expect(DeviceBattery.clampedLevel(55.6) == 56)
        #expect(DeviceBattery.clampedLevel(Double.nan) == nil)
    }

    @Test("R4: unknown enum strings fall back")
    func unknownEnums() throws {
        #expect(DeviceKind(parsing: "vision") == .other)
        #expect(AccessoryKind(parsing: "pencil") == .other)
        #expect(AccessoryComponent(parsing: "stem") == .main)
        let decoded = try JSONDecoder().decode([DeviceKind].self, from: Data(#"["mac","vision"]"#.utf8))
        #expect(decoded == [.mac, .other])
    }

    @Test("AC6 (model side): schemaVersion above current sets needsNewerApp")
    func needsNewerApp() {
        var d = battery()
        #expect(!d.needsNewerApp)
        d.schemaVersion = 2
        #expect(d.needsNewerApp)
    }

    @Test("AC9: readingDate caps a writer clock that runs ahead")
    func ac9ReadingDate() {
        let ahead = battery(updatedAt: now + 10 * minute, serverModifiedAt: now - minute)
        #expect(ahead.readingDate(now: now) == now - minute)
        #expect(ahead.age(now: now) == minute)

        let future = battery(updatedAt: now + 5 * minute)
        #expect(future.readingDate(now: now) == now)
        #expect(future.age(now: now) == 0)

        // Offline writer: uploaded later, readingDate stays at updatedAt.
        let offline = battery(updatedAt: now - hour, serverModifiedAt: now - minute)
        #expect(offline.readingDate(now: now) == now - hour)
    }

    @Test("AC16: charging flags from each power state")
    func ac16ChargingFlags() {
        // (charging, onExternalPower, full) as ADR-0010 rule 6 maps each BatteryReading.PowerState.
        let charging = ChargingFlags(charging: true, onExternalPower: true, full: false)
        let full = ChargingFlags(charging: false, onExternalPower: true, full: true)
        let pluggedIn = ChargingFlags(charging: false, onExternalPower: true, full: false)
        let unplugged = ChargingFlags(charging: false, onExternalPower: false, full: false)
        let unknown = ChargingFlags(charging: false, onExternalPower: nil, full: false)
        #expect((charging.isCharging, charging.isPluggedIn) == (true, true))
        #expect((full.isCharging, full.isPluggedIn) == (true, true))
        #expect((pluggedIn.isCharging, pluggedIn.isPluggedIn) == (false, true))
        #expect((unplugged.isCharging, unplugged.isPluggedIn) == (false, false))
        #expect(unknown.isCharging == false && unknown.isPluggedIn == nil)
    }

    @Test("AC17: default names and the in-app rename")
    func ac17DeviceName() {
        #expect(DefaultDeviceName.current(kind: .iphone) == "iPhone")
        #expect(DefaultDeviceName.current(kind: .watch) == "Apple Watch")
        #expect(DefaultDeviceName.current(kind: .ipad) == "iPad")
        #expect(DefaultDeviceName.resolved(kind: .iphone, thisDeviceName: "Work Phone") == "Work Phone")
        #expect(DefaultDeviceName.resolved(kind: .iphone, thisDeviceName: "  ") == "iPhone")
        #expect(DefaultDeviceName.resolved(kind: .iphone, thisDeviceName: nil) == "iPhone")
        #expect(DefaultDeviceName.defaultName(kind: .mac, computerName: "Studio") == "Studio")
        #expect(DefaultDeviceName.defaultName(kind: .mac, computerName: nil) == "Mac")
        #expect(DefaultDeviceName.resolved(kind: .mac, thisDeviceName: "Laptop", computerName: "Studio") == "Laptop")
    }
}
