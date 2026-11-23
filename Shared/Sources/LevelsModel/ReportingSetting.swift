import Foundation
import Synchronization

/// Whether this device reports its battery (SYNC-001 R15a, ADR-0019 §6).
///
/// "Remove all my data" turns it off and only "Turn on reporting" turns it back on, across
/// relaunches: it lives in App Group `UserDefaults` under ``key`` (default `true`). The
/// reporter, sync and the list store all read the same value.
public final class ReportingSetting: Sendable {
    public static let key = "reportingEnabled"

    /// `nil` keeps the value in ``memory`` only.
    private let suite: Suite?
    private let memory: Mutex<Bool>

    private struct Suite: Sendable { var name: String? }

    /// - Parameter suiteName: the App Group ID; `nil` uses `UserDefaults.standard`.
    public init(suiteName: String?) {
        suite = Suite(name: suiteName)
        memory = Mutex(true)
    }

    private init(enabled: Bool) {
        suite = nil
        memory = Mutex(enabled)
    }

    /// A setting kept in memory only (tests, previews).
    public static func inMemory(enabled: Bool = true) -> ReportingSetting { ReportingSetting(enabled: enabled) }

    /// `true` unless reporting was turned off.
    public var isEnabled: Bool {
        guard let suite else { return memory.withLock { $0 } }
        guard let defaults = defaults(suite.name), defaults.object(forKey: Self.key) != nil else { return true }
        return defaults.bool(forKey: Self.key)
    }

    public func setEnabled(_ enabled: Bool) {
        guard let suite else {
            memory.withLock { $0 = enabled }
            return
        }
        defaults(suite.name)?.set(enabled, forKey: Self.key)
    }

    // `UserDefaults` is looked up per call so the setting holds only Sendable values.
    private func defaults(_ suiteName: String?) -> UserDefaults? {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName)
    }
}
