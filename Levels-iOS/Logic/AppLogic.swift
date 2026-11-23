// Pure logic of the iPhone app target, kept free of UIKit and SwiftUI so Levels-iOSTests can
// test it without a device.
import Foundation

/// RPT-002 R8: the "Keep this iPhone up to date" card shows until an App Intent run is seen
/// (`rpt.lastReport["appIntent"]` less than 7 days old) or the owner taps "Not now".
enum ShortcutsHint {
    static let dismissedKey = "rpt.hintDismissed"
    static let seenWindow: TimeInterval = 7 * 24 * 60 * 60

    static func isVisible(lastAppIntentReport: Date?, dismissed: Bool, now: Date) -> Bool {
        guard !dismissed else { return false }
        return !isSetUp(lastAppIntentReport: lastAppIntentReport, now: now)
    }

    /// UI-002 R8 checkmark: an automation (or a manual Shortcuts run) reported within 7 days.
    static func isSetUp(lastAppIntentReport: Date?, now: Date) -> Bool {
        guard let last = lastAppIntentReport else { return false }
        return now.timeIntervalSince(last) < seenWindow
    }
}

/// RPT-002 R3–R6: what "Report Battery" does with the reporter's answer. The hand-off may
/// take at most `timeout`; after that the intent still succeeds (sync owns any retry).
enum ReportBatteryRun {
    enum Outcome: Equatable, Sendable {
        /// A reading reached sync.
        case sent
        /// Unknown reading or no device ID yet (R6): success, nothing sent.
        case nothingSent
        /// Still running after the timeout (R3): success.
        case timedOut
        /// Any other error (R5): logged and swallowed, success.
        case failedQuietly
        /// The one failure Shortcuts sees (R5).
        case unavailable
    }

    static let timeout: Duration = .seconds(10)

    /// - Parameters:
    ///   - report: calls the reporter; returns `true` when a reading was sent. Throws
    ///     ``isUnavailable`` errors to fail the intent, anything else to be swallowed.
    ///   - isUnavailable: tells the one error that must reach Shortcuts.
    static func run(timeout: Duration = timeout,
                    isUnavailable: @escaping @Sendable (any Error) -> Bool,
                    report: @escaping @Sendable () async throws -> Bool) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return try await report() ? .sent : .nothingSent }
                catch { return isUnavailable(error) ? .unavailable : .failedQuietly }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

/// UI-002 R4 detail text that doesn't need SwiftUI.
enum DetailText {
    enum Charging: Equatable { case charging, pluggedInNotCharging, notCharging, noBattery }

    /// "Charging", "Plugged in, not charging", "Not charging", or "Plugged in · no battery".
    static func charging(level: Int?, isCharging: Bool, isPluggedIn: Bool?) -> Charging {
        guard level != nil else { return .noBattery }
        if isCharging { return .charging }
        return isPluggedIn == true ? .pluggedInNotCharging : .notCharging
    }

    /// "3 hours" for the stale line ("This device hasn't reported for 3 hours…"): the largest
    /// whole unit, at least one minute.
    static func staleAge(_ age: TimeInterval, locale: Locale = .current) -> String {
        let seconds = max(60, age)
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1)
                .locale(locale))
    }

    /// UI-002 edge case: names are trimmed to 40 characters.
    static let maxNameLength = 40

    /// The rename text field's value as saved: trimmed, cut to 40 characters, `nil` when empty
    /// (the default name, UI-002 R6).
    static func renameValue(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }
}
