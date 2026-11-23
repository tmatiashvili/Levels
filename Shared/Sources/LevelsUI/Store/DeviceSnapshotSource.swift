import Foundation
import LevelsModel

/// Where the UI gets its data (ADR-0003: `LevelsUI` never imports CloudKit). The app wires it to
/// SYNC-002's `SnapshotCache` plus sync and the reporter; a local-only (Mac-first) build wires it
/// to the cache and the reporter alone (``SnapshotCacheSource``).
public protocol DeviceSnapshotSource: Sendable {
    /// The SYNC-002 cache contents.
    func current() async throws -> SnapshotFile
    /// Fires after the cache changes.
    func changes() -> AsyncStream<Void>
    /// `true`: the reporter reports `.userRefresh` and sync runs `refresh(.userPull)`;
    /// `false`: `.foreground` and `refresh(.foreground)` (lead's call 13). Use
    /// ``ReportReason/refresh(userInitiated:)`` to pick the reason.
    func requestRefresh(userInitiated: Bool) async throws
    /// Saves `DisplayPreferences.thisDeviceName`, then reports (ADR-0008 W8). `nil` = default name.
    func setThisDeviceName(_ name: String?) async
    /// Deletes a record and its accessories (SYNC-001 R15).
    func remove(_ id: DeviceID) async throws
    /// Deletes all data and stops reporting (SYNC-001 R15a).
    func removeAllData() async throws
    /// Turns reporting back on after ``removeAllData()`` (SYNC-001 R15a).
    func resumeReporting() async
}

extension ReportReason {
    /// The report reason for a list refresh: `.userRefresh` for pull to refresh, the refresh
    /// button and ⌘R; `.foreground` for foreground and popover-open (lead's call 13).
    public static func refresh(userInitiated: Bool) -> ReportReason {
        userInitiated ? .userRefresh : .foreground
    }
}

extension RefreshReason {
    /// The sync fetch reason for a list refresh (`.userPull` or `.foreground`).
    public static func refresh(userInitiated: Bool) -> RefreshReason {
        userInitiated ? .userPull : .foreground
    }
}
