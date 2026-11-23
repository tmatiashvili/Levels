// Unit tests for the logic in the Levels-iOS target (RPT-001 R2, RPT-002 AC2–AC6, UI-002 R4–R6).
import Foundation
import LevelsReaders
import Testing
import UIKit
@testable import Levels

@Suite struct ShortcutsHintTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func showsWhenNeverRun() {
        #expect(ShortcutsHint.isVisible(lastAppIntentReport: nil, dismissed: false, now: now))
    }

    @Test func hiddenWhenRunTwoDaysAgo() {  // RPT-002 AC6
        #expect(!ShortcutsHint.isVisible(lastAppIntentReport: now - 2 * 86_400, dismissed: false, now: now))
        #expect(ShortcutsHint.isSetUp(lastAppIntentReport: now - 2 * 86_400, now: now))
    }

    @Test func showsAgainAfterEightDays() {  // RPT-002 AC6
        #expect(ShortcutsHint.isVisible(lastAppIntentReport: now - 8 * 86_400, dismissed: false, now: now))
        #expect(!ShortcutsHint.isSetUp(lastAppIntentReport: now - 8 * 86_400, now: now))
    }

    @Test func hiddenOnceDismissed() {  // RPT-002 R8 "Not now"
        #expect(!ShortcutsHint.isVisible(lastAppIntentReport: nil, dismissed: true, now: now))
    }
}

@Suite struct ReportBatteryRunTests {
    struct Unavailable: Error {}
    struct Network: Error {}
    let isUnavailable: @Sendable (any Error) -> Bool = { $0 is Unavailable }

    @Test func sentWhenReporterSends() async {  // RPT-002 AC2
        let calls = Counter()
        let outcome = await ReportBatteryRun.run(isUnavailable: isUnavailable) {
            await calls.increment()
            return true
        }
        #expect(outcome == .sent)
        #expect(await calls.value == 1)
    }

    @Test func unknownReadingIsSuccess() async {  // RPT-002 R6
        #expect(await ReportBatteryRun.run(isUnavailable: isUnavailable) { false } == .nothingSent)
    }

    @Test func hangingReporterTimesOut() async {  // RPT-002 AC3 (shortened timeout)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await ReportBatteryRun.run(timeout: .milliseconds(200), isUnavailable: isUnavailable) {
            try await Task.sleep(for: .seconds(60))
            return true
        }
        #expect(outcome == .timedOut)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func unavailableFails() async {  // RPT-002 AC4
        #expect(await ReportBatteryRun.run(isUnavailable: isUnavailable) { throw Unavailable() } == .unavailable)
    }

    @Test func otherErrorsAreSwallowed() async {  // RPT-002 AC5
        #expect(await ReportBatteryRun.run(isUnavailable: isUnavailable) { throw Network() } == .failedQuietly)
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}

@Suite struct DetailTextTests {
    @Test func chargingLines() {  // UI-002 R4
        #expect(DetailText.charging(level: 50, isCharging: true, isPluggedIn: true) == .charging)
        #expect(DetailText.charging(level: 50, isCharging: false, isPluggedIn: true) == .pluggedInNotCharging)
        #expect(DetailText.charging(level: 50, isCharging: false, isPluggedIn: false) == .notCharging)
        #expect(DetailText.charging(level: 50, isCharging: false, isPluggedIn: nil) == .notCharging)
        #expect(DetailText.charging(level: nil, isCharging: false, isPluggedIn: true) == .noBattery)
    }

    @Test func staleAgeUsesLargestUnit() {  // UI-002 R4, AC4
        let en = Locale(identifier: "en_US")
        #expect(DetailText.staleAge(3 * 3600 + 300, locale: en) == "3 hours")
        #expect(DetailText.staleAge(2 * 86_400 + 3600, locale: en) == "2 days")
        #expect(DetailText.staleAge(10, locale: en) == "1 minute")
    }

    @Test func renameTrimsCutsAndResets() {  // UI-002 R6, AC5, edge case "very long name"
        #expect(DetailText.renameValue("  Work Phone ") == "Work Phone")
        #expect(DetailText.renameValue("   ") == nil)
        #expect(DetailText.renameValue("") == nil)
        #expect(DetailText.renameValue(String(repeating: "x", count: 60))?.count == 40)
    }
}

@Suite struct UIDeviceReadingTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func mapsLevelAndState() {  // RPT-001 R2, AC1
        let r = UIDeviceBatteryReader.reading(rawLevel: 0.85, state: .charging, lowPowerMode: false, now: now)
        #expect(r.level == 85)
        #expect(r.powerState == .charging)
        #expect(r.powerState.chargingFlags.isCharging)
        #expect(r.powerState.chargingFlags.isPluggedIn == true)
        #expect(!r.isLowPowerMode)
        #expect(r.readAt == now)
    }

    @Test func statesMapOneToOne() {  // RPT-001 R2
        #expect(UIDeviceBatteryReader.reading(rawLevel: 0.5, state: .unplugged, lowPowerMode: true, now: now).powerState == .unplugged)
        #expect(UIDeviceBatteryReader.reading(rawLevel: 1, state: .full, lowPowerMode: false, now: now).powerState == .full)
    }

    @Test func simulatorReadingIsAReadFailure() {  // RPT-001 R3, AC2 (−1.0 → nil)
        let r = UIDeviceBatteryReader.reading(rawLevel: -1, state: .unknown, lowPowerMode: false, now: now)
        #expect(r.level == nil)
        #expect(r.isReadFailure)
    }
}

@Suite struct BackgroundRefreshTests {
    @Test func identifierAndDelay() {  // RPT-001 R6, AC12
        #expect(BackgroundRefresh.identifier.hasSuffix(".levels.battery-refresh"))
        #expect(BackgroundRefresh.earliestDelay >= 29 * 60)
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(permitted == [BackgroundRefresh.identifier])
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes?.contains("fetch") == true)
    }
}
