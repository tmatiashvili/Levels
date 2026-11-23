import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

/// Fixtures in `Fixtures/` (MAC-003 Tests). Captured on the owner's MacBook (macOS 27.2.1,
/// 2026-11-23) with addresses, serials and personal names replaced by fakes:
/// - `sp-airpods-not-connected.json`: real `system_profiler SPBluetoothDataType -json`; the
///   AirPods are paired but not connected, with cached levels under `device_not_connected`.
/// - `sp-sandboxed.json`: real output of the same command run inside the App Sandbox.
/// - `hid-internal-only.json`: the real `AppleDeviceManagementHIDEventService` keys (one
///   service, the built-in keyboard/trackpad, no `BatteryPercent`).
/// - `sp-airpods-connected.json`: the real file with the AirPods entry moved under
///   `device_connected` (no accessory was connected during capture).
/// - `sp-single-and-broken.json`, `hid-magic.json`: hand-written in the same shape, for
///   single-battery devices, Magic peripherals (key names per ADR-0015) and R5 cases.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func hidServices(_ name: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [[String: Any]])
    }
}

@Suite("MAC-003 system_profiler parser (R2, R3, R5)")
struct SystemProfilerParserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func R2_notConnectedAirPodsAreIgnoredEvenWithCachedLevels() throws {
        let scan = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-airpods-not-connected"), now: now)
        #expect(scan.readings.isEmpty)
        #expect(scan.problems.isEmpty)
        #expect(!scan.headphonesConnected)
    }

    @Test func R2_R3a_connectedAirPodsGiveLeftRightCase() throws {
        let scan = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-airpods-connected"), now: now)
        #expect(scan.problems.isEmpty)
        #expect(scan.headphonesConnected)
        let byComponent = Dictionary(uniqueKeysWithValues: scan.readings.map { ($0.component, $0) })
        #expect(scan.readings.count == 3)  // the iPhone has no battery key; "Old AirPods" is not connected
        #expect(byComponent[.left]?.level == 40)
        #expect(byComponent[.right]?.level == 35)
        #expect(byComponent[.case]?.level == 80)
        for r in scan.readings {
            #expect(r.kind == .airpods)
            #expect(r.name == "TPods")
            #expect(r.key == "00:11:22:33:44:04")
            #expect(r.readAt == now)
        }
    }

    @Test func R2_singleBatteryDevicesUseMain() throws {
        let scan = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-single-and-broken"), now: now)
        let beats = try #require(scan.readings.first { $0.name == "Beats Flex" })
        #expect(beats.component == .main && beats.level == 70 && beats.kind == .airpods)
        let mouse = try #require(scan.readings.first { $0.name == "Logi Mouse" })
        #expect(mouse.component == .main && mouse.level == 55 && mouse.kind == .mouse)
        #expect(scan.headphonesConnected)
    }

    @Test func R5_badEntriesAreDroppedWholeAndLoggedWithoutAddresses() throws {
        let scan = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-single-and-broken"), now: now)
        #expect(Set(scan.readings.map(\.name)) == ["Beats Flex", "Logi Mouse"])  // the speaker has no battery: silent
        #expect(scan.problems == [
            "system_profiler: a connected device with a battery has no valid device_address",
            "system_profiler: device_batteryLevelLeft is not an NN% value",
            "system_profiler: unknown battery key device_batteryLevelLeftBud",
        ])
        #expect(!scan.problems.contains { $0.contains("00:11") })
    }

    @Test func R5_sandboxedOrForeignOutputReportsNothing() throws {
        let sandboxed = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-sandboxed"), now: now)
        #expect(sandboxed.readings.isEmpty)
        #expect(sandboxed.problems == ["system_profiler: no Bluetooth controller in the output"])
        for bad in ["", "not json", "{\"Other\":[]}", "{\"SPBluetoothDataType\":{}}"] {
            let scan = SystemProfilerBluetoothParser.parse(Data(bad.utf8), now: now)
            #expect(scan.readings.isEmpty)
            #expect(scan.problems == ["system_profiler: output is not the SPBluetoothDataType JSON"])
        }
    }

    @Test(arguments: [("45%", 45), ("0%", 0), ("100%", 100), (" 5% ", 5)])
    func R5_percentAcceptsNNPercent(raw: String, value: Int) {
        #expect(SystemProfilerBluetoothParser.percent(raw) == value)
    }

    @Test(arguments: ["45", "101%", "-5%", "%", "4.5%", "abc%", "1000%", "４５%"])
    func R5_percentRejectsEverythingElse(raw: String) {
        #expect(SystemProfilerBluetoothParser.percent(raw) == nil)
    }
}

@Suite("MAC-003 IOKit HID parser (R1, R5)")
struct HIDParserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func R1_internalKeyboardWithoutBatteryIsSkipped() throws {
        let scan = HIDAccessoryParser.parse(try Fixture.hidServices("hid-internal-only"), now: now)
        #expect(scan == .empty)
    }

    @Test func R1_magicPeripheralsReportMainWithKindFromProduct() throws {
        let scan = HIDAccessoryParser.parse(try Fixture.hidServices("hid-magic"), now: now)
        let byName = Dictionary(scan.readings.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(scan.readings.count == 3)  // two keyboard services, one record
        #expect(byName["Magic Mouse"]?.kind == .mouse)
        #expect(byName["Magic Mouse"]?.level == 64)
        #expect(byName["Magic Mouse"]?.key == "00:11:22:33:44:20")
        #expect(byName["Magic Keyboard"]?.kind == .keyboard)
        #expect(byName["Magic Trackpad"]?.kind == .trackpad)
        #expect(byName["Magic Trackpad"]?.level == 12)
        #expect(scan.readings.allSatisfy { $0.component == .main })
        #expect(!scan.headphonesConnected)
    }

    @Test func R5_missingAddressOrNonIntegerLevelIsNotReported() throws {
        let scan = HIDAccessoryParser.parse(try Fixture.hidServices("hid-magic"), now: now)
        #expect(!scan.readings.contains { $0.name == "Broken Trackpad" || $0.name == "Weird Mouse" })
        #expect(scan.problems == ["IOKit: a HID device with BatteryPercent has no valid DeviceAddress",
                                  "IOKit: BatteryPercent is not an integer 0–100"])
    }

    @Test func R1_addressAsSixBytes() {
        let scan = HIDAccessoryParser.parse([["BatteryPercent": 50, "Product": "Magic Mouse",
                                              "DeviceAddress": Data([0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03])]], now: now)
        #expect(scan.readings.first?.key == "AA:BB:CC:01:02:03")
    }

    @Test func R5_boolAndOutOfRangeLevelsAreRejected() {
        for bad: Any in [true, 101, -1, 50.5] {
            let scan = HIDAccessoryParser.parse([["BatteryPercent": bad, "DeviceAddress": "00-11-22-33-44-55"]], now: now)
            #expect(scan.readings.isEmpty, "\(bad)")
            #expect(scan.problems.count == 1)
        }
    }
}

@Suite("MAC-003 identity and mapping (R3, R3a)")
struct AccessoryMappingTests {
    let mac = DeviceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [("aa-bb-cc-dd-ee-ff", "AA:BB:CC:DD:EE:FF"), ("AA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:FF"),
                      ("0a:1B:2c:3D:4e:5F", "0A:1B:2C:3D:4E:5F")])
    func R3_addressIsNormalisedUppercaseColon(raw: String, key: String) {
        #expect(BluetoothAddress.normalized(raw) == key)
    }

    @Test(arguments: ["", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:00", "AA:BB:CC:DD:EE:GG", "AABBCCDDEEFF", "A:BB:CC:DD:EE:FF"])
    func R3_badAddressesAreRejected(raw: String) {
        #expect(BluetoothAddress.normalized(raw) == nil)
    }

    @Test func R3_recordIDIsSYNC002UUIDv5AndMatchesAC8Golden() {
        let r = AccessoryReading(key: "AA:BB:CC:DD:EE:FF", name: "AirPods Pro", kind: .airpods, component: .left, level: 40, readAt: now)
        #expect(r.id.recordName == "060fa350-0031-53ce-8273-1c941a6da860")  // SYNC-002 AC8 golden value
    }

    @Test func R3_R3a_mapsToAccessoryRecordWithoutTheRawAddress() throws {
        let readings = [AccessoryComponent.left, .right, .case].map {
            AccessoryReading(key: "AA:BB:CC:DD:EE:FF", name: "AirPods Pro", kind: .airpods, component: $0, level: 50, readAt: now)
        }
        let devices = readings.map { $0.deviceBattery(parent: mac) }
        #expect(Set(devices.map(\.id)).count == 3)
        #expect(Set(devices.map { $0.accessory?.groupID }).count == 1)  // one AirPods row (UI-001 R13)
        for d in devices {
            #expect(d.kind == .accessory)
            #expect(d.accessory?.parentDeviceID == mac)
            #expect(d.accessory?.kind == .airpods)
            #expect(d.level == 50)
            #expect(d.isCharging == false && d.isPluggedIn == nil && d.isLowPowerMode == nil)
            #expect(d.updatedAt == now)
            #expect(d.name == "AirPods Pro")
            // ADR-0019: the raw address appears nowhere in the stored value.
            let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self).uppercased()
            #expect(!json.contains("AA:BB:CC:DD:EE:FF") && !json.contains("AABBCCDDEEFF"))
        }
    }

    @Test func R3_groupIDDiffersFromEveryComponentIDAndPerAccessory() {
        let g = DeviceID.accessoryGroup(key: "AA:BB:CC:DD:EE:FF")
        #expect(g == DeviceID.accessoryGroup(key: "AA:BB:CC:DD:EE:FF"))
        #expect(g != DeviceID.accessoryGroup(key: "AA:BB:CC:DD:EE:00"))
        for c in AccessoryComponent.allCases {
            #expect(DeviceID(g) != DeviceID.accessory(key: "AA:BB:CC:DD:EE:FF", component: c))
        }
    }

    @Test func mergePrefersFirstSourcePerRecord() {
        let hid = AccessoryScan(readings: [AccessoryReading(key: "AA:BB:CC:DD:EE:FF", name: "Magic Mouse", kind: .mouse,
                                                            component: .main, level: 63, readAt: now)])
        let sp = AccessoryScan(readings: [AccessoryReading(key: "AA:BB:CC:DD:EE:FF", name: "Mouse", kind: .mouse,
                                                           component: .main, level: 60, readAt: now)],
                               problems: ["x"], headphonesConnected: true)
        let merged = AccessoryScan.merged([hid, sp])
        #expect(merged.readings.map(\.level) == [63])
        #expect(merged.problems == ["x"])
        #expect(merged.headphonesConnected)
    }
}
