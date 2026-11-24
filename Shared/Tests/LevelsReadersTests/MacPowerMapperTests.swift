import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

/// MAC-002 AC1–AC3 and R1–R5 on fixture IOPS dictionaries (no IOKit).
@Suite("MAC-002 MacPowerMapper")
struct MacPowerMapperTests {
    typealias K = MacPowerMapper.Key
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func battery(current: Any? = 100, max: Any? = 100, charging: Bool = false, charged: Bool = false,
                 state: String = MacPowerMapper.Value.batteryPower, present: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            K.type: MacPowerMapper.Value.internalBattery,
            K.isPresent: present,
            K.isCharging: charging,
            K.isCharged: charged,
            K.powerSourceState: state,
        ]
        if let current { d[K.currentCapacity] = current }
        if let max { d[K.maxCapacity] = max }
        return d
    }

    let ups: [String: Any] = [
        "Type": "UPS", "Is Present": true, "Current Capacity": 50, "Max Capacity": 100,
        "Power Source State": "AC Power", "Is Charging": true,
    ]

    func map(_ descriptions: [[String: Any]]?, lowPower: Bool = false) -> BatteryReading {
        MacPowerMapper.reading(from: descriptions, lowPowerMode: lowPower, now: now)
    }

    @Test func AC1_levelIsNormalisedByMaxCapacity() {
        #expect(map([battery(current: 4074, max: 6210)]).level == 66)
    }

    @Test func AC1a_fullOnACMapsToFullAndModelCharging() {
        let r = map([battery(current: 100, charging: false, charged: true, state: MacPowerMapper.Value.acPower)])
        #expect(r.powerState == .full)
        #expect(r.level == 100)
        #expect(r.powerState.chargingFlags == ChargingFlags(charging: true, onExternalPower: true, full: false))
        #expect(r.powerState.chargingFlags.isCharging == true)
        #expect(r.powerState.chargingFlags.isPluggedIn == true)
    }

    @Test func AC2_heldAt80OnACIsPluggedInNotCharging() {
        let r = map([battery(current: 80, charging: false, charged: false, state: MacPowerMapper.Value.acPower)])
        #expect(r.powerState == .pluggedIn)
        #expect(r.powerState.chargingFlags.isCharging == false)
        #expect(r.powerState.chargingFlags.isPluggedIn == true)
    }

    @Test func AC3_noSourcesOrUPSOnlyIsNoBattery() {
        for descriptions in [[], [ups]] {
            let r = map(descriptions)
            #expect(r.level == nil)
            #expect(r.powerState == .pluggedIn)
            #expect(!r.isReadFailure)
        }
    }

    @Test func AC3_nilDescriptionsIsReadFailure() {
        let r = map(nil)
        #expect(r.level == nil)
        #expect(r.powerState == .unknown)
        #expect(r.isReadFailure)
    }

    @Test func R1_ignoresUPSAndPicksFirstPresentInternalBattery() {
        let removed = battery(current: 10, present: false)
        let r = map([ups, removed, battery(current: 42), battery(current: 90)])
        #expect(r.level == 42)
        #expect(r.powerState == .unplugged)
    }

    @Test func R1_batteryNotPresentIsNoBattery() {
        let r = map([battery(current: 50, present: false)])
        #expect(r.level == nil)
        #expect(r.powerState == .pluggedIn)
    }

    @Test(arguments: [
        (current: 50 as Int?, max: nil as Int?, expected: 50 as Int?),   // max missing: current as percent
        (current: 50, max: 0, expected: 50),                             // max ≤ 0
        (current: 150, max: -1, expected: 100),                          // clamped
        (current: 6210, max: 6210, expected: 100),                       // Intel mAh-like
        (current: 7000, max: 6210, expected: 100),                       // above max: clamped
        (current: 31, max: 6210, expected: 0),                           // 0.5 % rounds to 0
        (current: 33, max: 6210, expected: 1),                           // 0.53 % rounds to 1
        (current: nil, max: 100, expected: nil),                         // no current
    ])
    func R2_levelFormula(current: Int?, max: Int?, expected: Int?) {
        #expect(map([battery(current: current, max: max)]).level == expected)
    }

    @Test func R2_acceptsNSNumberValues() {
        let r = map([battery(current: NSNumber(value: 4074), max: NSNumber(value: 6210), charging: true)])
        #expect(r.level == 66)
        #expect(r.powerState == .charging)
    }

    @Test(arguments: [
        (charging: true, charged: false, onAC: true, expected: BatteryReading.PowerState.charging),
        (charging: true, charged: false, onAC: false, expected: .charging),
        (charging: false, charged: true, onAC: true, expected: .full),
        (charging: false, charged: true, onAC: false, expected: .unplugged),
        (charging: false, charged: false, onAC: true, expected: .pluggedIn),
        (charging: false, charged: false, onAC: false, expected: .unplugged),
    ])
    func R3_powerState(charging: Bool, charged: Bool, onAC: Bool, expected: BatteryReading.PowerState) {
        let state = onAC ? MacPowerMapper.Value.acPower : MacPowerMapper.Value.batteryPower
        #expect(map([battery(charging: charging, charged: charged, state: state)]).powerState == expected)
    }

    @Test func R4_lowPowerModeIsCarried() {
        #expect(map([battery()], lowPower: true).isLowPowerMode)
        #expect(map(nil, lowPower: true).isLowPowerMode)
        #expect(!map([battery()], lowPower: false).isLowPowerMode)
    }

    @Test func R5_noBatteryMapsToNilLevelPluggedInFlags() {
        let flags = map([]).powerState.chargingFlags
        #expect(flags.isCharging == false)
        #expect(flags.isPluggedIn == true)
    }
}

/// ADR-0010 rules 1 and 6, SYNC-002 R16.
@Suite("ADR-0010 BatteryReading")
struct BatteryReadingTests {
    @Test(arguments: [
        (BatteryReading.PowerState.charging, true, true as Bool?),
        (.full, true, true),
        (.pluggedIn, false, true),
        (.unplugged, false, false),
        (.unknown, false, nil),
    ])
    func SYNC002_R16_powerStateToChargingFlags(state: BatteryReading.PowerState, isCharging: Bool, isPluggedIn: Bool?) {
        #expect(state.chargingFlags.isCharging == isCharging)
        #expect(state.chargingFlags.isPluggedIn == isPluggedIn)
    }

    @Test func ADR0010_rule1_levelFromFraction() {
        // RPT-001 AC2: 0.0, 0.004, 0.996, 1.0, −1.0 → 0, 0, 100, 100, nil.
        #expect([0.0, 0.004, 0.996, 1.0, -1.0].map(BatteryReading.level(fromFraction:)) == [0, 0, 100, 100, nil])
        #expect(BatteryReading.level(fromFraction: .nan) == nil)
        #expect(BatteryReading.level(fromFraction: 1.7) == 100)
    }

    @Test func initClampsLevel() {
        let at = Date()
        #expect(BatteryReading(level: 140, powerState: .full, isLowPowerMode: false, readAt: at).level == 100)
        #expect(BatteryReading(level: -3, powerState: .unplugged, isLowPowerMode: false, readAt: at).level == 0)
    }

    @Test func R7_differsIgnoresReadAt() {
        let a = BatteryReading(level: 50, powerState: .unplugged, isLowPowerMode: false, readAt: Date(timeIntervalSince1970: 1))
        var b = a
        b.readAt = Date(timeIntervalSince1970: 99)
        #expect(!b.differsInValues(from: a))
        b.level = 51
        #expect(b.differsInValues(from: a))
        b = a; b.powerState = .charging
        #expect(b.differsInValues(from: a))
        b = a; b.isLowPowerMode = true
        #expect(b.differsInValues(from: a))
    }

    @Test func fixedReaderReturnsScriptThenRepeatsLast() async {
        let at = Date()
        let r1 = BatteryReading(level: 1, powerState: .unplugged, isLowPowerMode: false, readAt: at)
        let r2 = BatteryReading(level: 2, powerState: .charging, isLowPowerMode: false, readAt: at)
        let reader = FixedBatteryReader([r1, r2])
        #expect(await reader.read() == r1)
        #expect(await reader.read() == r2)
        #expect(await reader.read() == r2)
        #expect(reader.readCount == 3)
        reader.emit(r1)
        reader.finish()
        var seen: [BatteryReading] = []
        for await r in reader.changes() { seen.append(r) }
        #expect(seen == [r1])
        #expect(await reader.read() == r1)
    }
}
