import Foundation

// The Foundation-only sync seam (ADR-0003, SYNC-001 Design). `BatterySyncService`
// in LevelsSync conforms to `BatterySyncing`; reporters and the UI depend only on these.

/// Sync state, published by `BatterySyncService` and cached for widgets (SYNC-001 R21, ADR-0017 §6).
public enum SyncStatus: Sendable, Equatable, Codable {
    case idle, syncing, signedOut, restricted, waitingForAccount, iCloudFull
    /// No iCloud at all by design: the free-team build (owner decision K) syncs nothing and
    /// writes only this device's own readings to the cache. Not an error; the UI shows no banner.
    case localOnly
    case misconfigured(code: Int)
    case offline(lastFetchAt: Date?)
}

/// Why a device reports its battery.
public enum ReportReason: String, Sendable, CaseIterable, Codable {
    case launch, foreground, batteryChange, chargerChange, backgroundRefresh, pushWake, appIntent, sleep, wake, heartbeat, userRefresh

    /// Urgent reports skip the 60 s minimum gap but keep the 10 s floor (SYNC-001 R5a, ADR-0008 W9).
    /// `.userRefresh` is pull to refresh, the refresh button or ⌘R.
    public var isUrgent: Bool {
        switch self {
        case .launch, .appIntent, .sleep, .wake, .chargerChange, .userRefresh: true
        case .foreground, .batteryChange, .backgroundRefresh, .pushWake, .heartbeat: false
        }
    }
}

/// What happened to a report.
public enum ReportOutcome: Sendable, Equatable {
    case uploaded
    case held(until: Date)
    case skipped
    case failed(retryAt: Date?)
}

/// Why sync fetches the zone (SYNC-001 `refresh(_:)`).
public enum RefreshReason: Sendable, Equatable, CaseIterable {
    case launch, foreground, push, backgroundRefresh, wake, networkReachable, timer, userPull
}

/// What reporters (RPT-001, RPT-004, MAC-002) depend on. `BatterySyncService` conforms; tests fake it.
public protocol BatterySyncing: Sendable {
    /// Hands the latest readings (own device plus any accessories) to sync.
    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome
    /// The current sync state.
    var status: SyncStatus { get async }
    /// Fetches changes (SYNC-001 R8–R10, MAC-001 R10/R10a/R11). Returns whether the cache is
    /// usable afterwards. The local-only stand-in has nothing to fetch.
    @discardableResult
    func refresh(_ reason: RefreshReason) async -> Bool
}

/// This device's stable ID (ADR-0007, SYNC-001 Design). `KeychainDeviceIdentity` in
/// LevelsReaders is the real one; ``FixedDeviceIdentity`` is the test double.
public protocol DeviceIdentityProviding: Sendable {
    /// The stored ID, created on first use. Returns `nil` when the Keychain is not readable
    /// yet (before first unlock): the caller skips reporting and tries later (ADR-0007 rule 1).
    func currentDeviceID() throws -> DeviceID?
}

/// A ``DeviceIdentityProviding`` that returns a fixed value (tests, previews).
public struct FixedDeviceIdentity: DeviceIdentityProviding {
    public let id: DeviceID?
    public init(_ id: DeviceID?) { self.id = id }
    public func currentDeviceID() throws -> DeviceID? { id }
}
