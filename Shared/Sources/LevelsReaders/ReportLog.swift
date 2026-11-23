import Foundation
import LevelsModel
import Synchronization

/// When each kind of report was last handed to sync successfully (RPT-001 R10).
///
/// Backed by App Group `UserDefaults` under ``key`` (`[String: Date]`, keyed by
/// `ReportReason.rawValue`), separate from the ADR-0009 snapshot cache. RPT-002 reads it.
public final class ReportLog: Sendable {
    public static let key = "rpt.lastReport"

    /// `nil` keeps the values in ``memory`` only.
    private let suite: Suite?
    private let memory = Mutex<[String: Date]>([:])

    private struct Suite: Sendable { var name: String? }

    /// - Parameter suiteName: the App Group ID; `nil` uses `UserDefaults.standard`.
    public init(suiteName: String?) {
        suite = Suite(name: suiteName)
    }

    private init() {
        suite = nil
    }

    /// A log that keeps its values in memory only (tests, previews).
    public static func inMemory() -> ReportLog { ReportLog() }

    /// `lastReport[reason]`, or `nil` if never recorded.
    public func lastReport(_ reason: ReportReason) -> Date? { all()[reason.rawValue] }

    /// Every recorded reason and its time.
    public func all() -> [String: Date] {
        guard let suite else { return memory.withLock { $0 } }
        return (defaults(suite.name)?.dictionary(forKey: Self.key) as? [String: Date]) ?? [:]
    }

    /// Sets `lastReport[reason] = date`.
    public func record(_ reason: ReportReason, at date: Date) {
        guard let suite else {
            memory.withLock { $0[reason.rawValue] = date }
            return
        }
        guard let defaults = defaults(suite.name) else { return }
        var values = (defaults.dictionary(forKey: Self.key) as? [String: Date]) ?? [:]
        values[reason.rawValue] = date
        defaults.set(values, forKey: Self.key)
    }

    // `UserDefaults` is looked up per call so the log holds only Sendable values.
    private func defaults(_ suiteName: String?) -> UserDefaults? {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName)
    }
}
