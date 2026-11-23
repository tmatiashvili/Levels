import Foundation
import Testing
import LevelsModel

/// SYNC-001 R15a: the reporting switch survives a relaunch.
@Suite("SYNC-001 R15a ReportingSetting")
struct ReportingSettingTests {
    @Test func defaultsOnAndPersistsInSuite() throws {
        let suite = "levels.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(ReportingSetting(suiteName: suite).isEnabled)
        ReportingSetting(suiteName: suite).setEnabled(false)
        #expect(!ReportingSetting(suiteName: suite).isEnabled)  // a new instance = a relaunch
        #expect(UserDefaults(suiteName: suite)?.object(forKey: ReportingSetting.key) as? Bool == false)
        ReportingSetting(suiteName: suite).setEnabled(true)
        #expect(ReportingSetting(suiteName: suite).isEnabled)
    }

    @Test func inMemory() {
        let s = ReportingSetting.inMemory(enabled: false)
        #expect(!s.isEnabled)
        s.setEnabled(true)
        #expect(s.isEnabled)
    }
}
