// RPT-002: the "Report Battery" App Intent that Shortcuts automations run on Battery Level and
// Charger triggers. Needs no entitlement, so it works on the free Personal Team. It runs in the
// app's process and shares the one `BatteryReporter` (registered in `LevelsApp.init`).
import AppIntents
import LevelsModel
import LevelsReaders
import os

struct ReportBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Report Battery"
    static let description = IntentDescription("Updates this iPhone's battery level in Levels and its widgets.")
    /// R2: entirely in the background, never opens the app (`openAppWhenRun` is deprecated).
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true

    @Dependency var reporter: BatteryReporter

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "reporting")

    /// R3–R6: report with `.appIntent`, wait at most 10 s, return no value and no dialog.
    func perform() async throws -> some IntentResult {
        let reporter = self.reporter
        let outcome = await ReportBatteryRun.run(
            isUnavailable: { ($0 as? ReportError) == .iCloudUnavailable },
            report: { try await reporter.reportNow(reason: .appIntent) != nil })
        Self.logger.notice("Report Battery intent: \(String(describing: outcome), privacy: .public)")
        await AppModel.shared.refreshLiveActivityAfterIntent()  // LIVE-001 R21; no-op without a Live Activity
        if outcome == .unavailable { throw ReportBatteryError.unavailable }
        return .result()
    }
}

/// R5: the only failure Shortcuts shows. Local-only sync never reports it; the iCloud and hub
/// builds do when their status says the data can't go anywhere.
enum ReportBatteryError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        "Levels can't send this battery right now. Open Levels to see why."
    }
}

/// R7: one App Shortcut, discoverable in Shortcuts and Spotlight.
struct LevelsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReportBatteryIntent(),
            phrases: [
                "Report battery with \(.applicationName)",
                "Update \(.applicationName)",
                "Send my battery to \(.applicationName)",
            ],
            shortTitle: "Report Battery",
            systemImageName: "battery.100percent")
    }
}
