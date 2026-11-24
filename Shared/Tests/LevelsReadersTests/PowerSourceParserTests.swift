import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

/// `pmset-airpods-in-case.xml`: real `pmset -g accps -xml` from the owner's MacBook
/// (2026-11-24 ~17:22, AirPods Pro 2 "TPods" charging in their case, **not connected** to
/// the Mac), with the Mac's serial and the accessory UUIDs replaced by fakes. The other
/// cases are built in the same shape by ``source(_:)``.
@Suite("MAC-003 power-source parser (AirPods charging, ADR-0015 amendment)")
struct PowerSourceParserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let address = "00:11:22:33:44:04"

    static func xml(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The owner's paired devices, from the real not-connected `system_profiler` fixture.
    static func paired() throws -> [PairedBluetoothDevice] {
        SystemProfilerBluetoothParser.pairedDevices(try Fixture.data("sp-airpods-not-connected"))
    }

    // MARK: Real capture

    @Test func realCapture_notConnectedAirPodsInCaseGiveLeftRightCaseCharging() throws {
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: try Self.paired(), now: now)
        #expect(scan.problems.isEmpty)
        #expect(!scan.headphonesConnected)  // heard, not connected: no 5-min headphone poll by itself
        let by = Dictionary(uniqueKeysWithValues: scan.readings.map { ($0.component, $0) })
        #expect(scan.readings.count == 3)
        #expect(by[.left]?.level == 100)
        #expect(by[.right]?.level == 100)
        #expect(by[.case]?.level == 93)
        for r in scan.readings {
            #expect(r.isCharging)
            #expect(r.isPluggedIn == true)  // "AC Power": buds in the case, case on its charger
            #expect(r.key == Self.address)
            #expect(r.name == "TPods")  // the case keeps the device name, not "TPods Case"
            #expect(r.kind == .airpods)
            #expect(r.readAt == now)
        }
    }

    @Test func realCapture_recordIDsMatchTheConnectedReadings() throws {
        let fromPower = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: try Self.paired(), now: now)
        let connected = SystemProfilerBluetoothParser.parse(try Fixture.data("sp-airpods-connected"), now: now)
        #expect(Set(fromPower.readings.map(\.id)) == Set(connected.readings.map(\.id)))
    }

    @Test func realCapture_deviceBatteryCarriesChargingAndHonestTime() throws {
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: try Self.paired(), now: now)
        let parent = DeviceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        for d in scan.readings.map({ $0.deviceBattery(parent: parent) }) {
            #expect(d.isCharging && d.isPluggedIn == true && d.updatedAt == now && d.isLowPowerMode == nil)
        }
    }

    @Test func realCapture_macInternalBatteryIsIgnored() throws {
        let parts = PowerSourceAccessoryParser.parts(try Self.xml("pmset-airpods-in-case")).parts
        #expect(parts.count == 3)
        #expect(Set(parts.map(\.component)) == [.left, .right, .case])
    }

    // MARK: Matching (never other people's AirPods)

    @Test func noPairedDeviceWithThatModelGivesNothing() throws {
        let others = try Self.paired().filter { $0.productID != 0x2024 }
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: others, now: now)
        #expect(scan.readings.isEmpty)
        #expect(scan.problems == ["pmset: an accessory power source matches no paired headphones"])
    }

    @Test func noPairedDevicesAtAllGivesNothing() throws {
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: [], now: now)
        #expect(scan.readings.isEmpty)
    }

    @Test func twoPairedOfTheSameModelArePickedByName() throws {
        let twin = PairedBluetoothDevice(key: "00:11:22:33:44:99", name: "Work Pods", kind: .airpods, vendorID: 0x4C,
                                         productID: 0x2024, isHeadphones: true, isConnected: false)
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"),
                                                    paired: try Self.paired() + [twin], now: now)
        #expect(scan.problems.isEmpty)
        #expect(scan.readings.count == 3 && scan.readings.allSatisfy { $0.key == Self.address })
    }

    @Test func twoPairedOfTheSameModelAndNameAreSkipped() throws {
        let twin = PairedBluetoothDevice(key: "00:11:22:33:44:99", name: "TPods", kind: .airpods, vendorID: 0x4C,
                                         productID: 0x2024, isHeadphones: true, isConnected: false)
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"),
                                                    paired: try Self.paired() + [twin], now: now)
        #expect(scan.readings.isEmpty)
        #expect(scan.problems == ["pmset: an accessory power source matches several paired headphones"])
    }

    @Test func aNonHeadphoneWithTheSameIDsIsNotAMatch() throws {
        let mouse = PairedBluetoothDevice(key: "00:11:22:33:44:99", name: "TPods", kind: .mouse, vendorID: 0x4C,
                                          productID: 0x2024, isHeadphones: false, isConnected: true)
        let scan = PowerSourceAccessoryParser.parse(try Self.xml("pmset-airpods-in-case"), paired: [mouse], now: now)
        #expect(scan.readings.isEmpty)
    }

    // MARK: Charging mapping

    @Test func budOutOfTheCaseIsNotChargingAndOnBattery() throws {
        let data = Self.source(parts: [
            Self.part("Left", level: 80, charging: false, state: "Battery Power"),
            Self.part("Right", level: 97, charging: true, state: "AC Power"),
        ]) + Self.source(single: Self.part("Case", level: 40, charging: false, state: "Battery Power", name: "TPods Case"))
        let scan = PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now)
        let by = Dictionary(uniqueKeysWithValues: scan.readings.map { ($0.component, $0) })
        #expect(by[.left]?.isCharging == false && by[.left]?.isPluggedIn == false && by[.left]?.level == 80)
        #expect(by[.right]?.isCharging == true && by[.right]?.isPluggedIn == true)
        #expect(by[.case]?.isCharging == false && by[.case]?.isPluggedIn == false && by[.case]?.level == 40)
    }

    @Test func fullOnPowerCountsAsChargingPerChargingFlags() throws {
        let data = Self.source(single: Self.part("Case", level: 100, charging: false, state: "AC Power", charged: true,
                                                 name: "TPods Case"))
        let scan = PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now)
        #expect(scan.readings.first?.isCharging == true)  // SYNC-002 R16: on power and full
    }

    @Test func unknownPowerStateLeavesPluggedInUnknown() throws {
        let data = Self.source(single: Self.part("Case", level: 50, charging: true, state: nil, name: "TPods Case"))
        let r = try #require(PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now).readings.first)
        #expect(r.isCharging && r.isPluggedIn == nil)
    }

    // MARK: Nothing heard, nothing written; never guess (R5)

    @Test func notPresentSourceGivesNoReading() throws {
        let data = Self.source(single: Self.part("Case", level: 50, charging: true, state: "AC Power", name: "TPods Case"),
                               present: false)
        let scan = PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now)
        #expect(scan.readings.isEmpty && scan.problems.isEmpty)
    }

    @Test func emptyOrGarbageOutputGivesNothing() throws {
        for data in [Data(), Data("pmset: error".utf8), Data("<?xml nope".utf8)] {
            let scan = PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now)
            #expect(scan.readings.isEmpty)
        }
    }

    @Test func unknownPartDropsTheWholeSource() throws {
        let data = Self.source(parts: [
            Self.part("Left", level: 80, charging: false, state: "AC Power"),
            Self.part("Middle", level: 80, charging: false, state: "AC Power"),
        ])
        let scan = PowerSourceAccessoryParser.parse(data, paired: try Self.paired(), now: now)
        #expect(scan.readings.isEmpty)
        #expect(scan.problems == ["pmset: unknown Part Identifier Middle"])
    }

    @Test func badLevelOrChargingDropsTheSource() throws {
        var bad = Self.part("Case", level: 50, charging: true, state: "AC Power", name: "TPods Case")
        bad["Current Capacity"] = 150
        var noFlag = Self.part("Case", level: 50, charging: true, state: "AC Power", name: "TPods Case")
        noFlag["Is Charging"] = "yes"
        for p in [bad, noFlag] {
            let scan = PowerSourceAccessoryParser.parse(Self.source(single: p), paired: try Self.paired(), now: now)
            #expect(scan.readings.isEmpty && scan.problems.count == 1)
        }
    }

    @Test func singleBatteryHeadphonesUseMain() throws {
        var p = Self.part("Case", level: 70, charging: false, state: "Battery Power")
        p["Part Identifier"] = nil
        let scan = PowerSourceAccessoryParser.parse(Self.source(single: p), paired: try Self.paired(), now: now)
        #expect(scan.readings.map(\.component) == [.main])
    }

    // MARK: Fingerprint (change trigger)

    @Test func fingerprintIgnoresSourceIDsButSeesChargingChanges() throws {
        let real = try Self.xml("pmset-airpods-in-case")
        let renumbered = Data(String(decoding: real, as: UTF8.self)
            .replacingOccurrences(of: "<integer>42013663</integer>", with: "<integer>42019999</integer>").utf8)
        #expect(PowerSourceAccessoryParser.fingerprint(real) == PowerSourceAccessoryParser.fingerprint(renumbered))
        let text = String(decoding: real, as: UTF8.self)
        let higher = Data(text.replacingOccurrences(of: "<integer>93</integer>", with: "<integer>94</integer>").utf8)
        #expect(PowerSourceAccessoryParser.fingerprint(real) != PowerSourceAccessoryParser.fingerprint(higher))
        // The case (first accessory source) stops charging.
        let caseStart = try #require(text.range(of: "Audio Battery Case"))
        let chargingFlag = try #require(text.range(of: "<key>Is Charging</key>\n\t<true/>", range: caseStart.upperBound..<text.endIndex))
        let stopped = Data(text.replacingCharacters(in: chargingFlag, with: "<key>Is Charging</key>\n\t<false/>").utf8)
        #expect(PowerSourceAccessoryParser.fingerprint(real) != PowerSourceAccessoryParser.fingerprint(stopped))
        let scan = PowerSourceAccessoryParser.parse(stopped, paired: try Self.paired(), now: now)
        #expect(scan.readings.first { $0.component == .case }?.isCharging == false)
        #expect(scan.readings.first { $0.component == .left }?.isCharging == true)
        #expect(PowerSourceAccessoryParser.fingerprint(Data()).isEmpty)
    }

    // MARK: system_profiler paired devices

    @Test func pairedDevicesListNotConnectedAirPodsWithModel() throws {
        let tpods = try #require(try Self.paired().first { $0.name == "TPods" })
        #expect(tpods.key == Self.address && tpods.vendorID == 0x4C && tpods.productID == 0x2024)
        #expect(tpods.isHeadphones && !tpods.isConnected && tpods.kind == .airpods)
        #expect(SystemProfilerBluetoothParser.hexID("0x2024") == 0x2024)
        #expect(SystemProfilerBluetoothParser.hexID("2024") == nil)
        #expect(SystemProfilerBluetoothParser.pairedDevices(Data("[]".utf8)).isEmpty)
    }

    // MARK: Builders, in the shape of the real capture

    static func part(_ id: String, level: Int, charging: Bool, state: String?, charged: Bool = false,
                     name: String = "TPods") -> [String: Any] {
        var d: [String: Any] = [
            "Type": "Accessory Source", "Transport Type": "Bluetooth LE", "Is Present": true,
            "Part Identifier": id, "Name": name, "Vendor ID": 76, "Product ID": 8228,
            "Current Capacity": level, "Max Capacity": 100, "Is Charging": charging, "Is Charged": charged ? 1 : 0,
            "Group Identifier": "00000000-0000-0000-0000-0000000000A1",
        ]
        if let state { d["Power Source State"] = state }
        return d
    }

    static func source(parts: [[String: Any]]) -> Data {
        var combined = part("Combined", level: 0, charging: false, state: "AC Power")
        combined["Combined Parts"] = parts
        return plist(combined)
    }

    static func source(single: [String: Any], present: Bool = true) -> Data {
        var d = single
        d["Is Present"] = present
        return plist(d)
    }

    static func plist(_ d: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)) ?? Data()
    }
}
