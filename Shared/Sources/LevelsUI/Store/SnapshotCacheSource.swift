import Foundation
import LevelsModel

/// A local-only ``DeviceSnapshotSource`` over SYNC-002's ``SnapshotCache`` (no iCloud, no push):
/// the Mac-first build, where the only writer is this device's own reporter.
///
/// `report` asks the reporter for a reading with the given reason (it writes the cache through
/// its `BatterySyncing`); the app calls ``notifyChanged()`` after any other cache write.
public final class SnapshotCacheSource: DeviceSnapshotSource {
    public typealias Report = @Sendable (ReportReason) async -> Void
    public typealias RemoveAllData = @Sendable () async throws -> Void

    private let cache: SnapshotCache
    private let preferences: any DisplayPreferencesStore
    private let reporting: ReportingSetting
    private let removeAll: RemoveAllData
    private let report: Report
    private let broadcaster = ChangeBroadcaster()

    /// - Parameters:
    ///   - reporting: SYNC-001 R15a; read for ``isReportingEnabled``, turned on by ``resumeReporting()``.
    ///   - removeAllData: the sync side of R15a (`LocalOnlySyncService.removeAllData()`): resets
    ///     the cache, reloads widgets and turns `reporting` off.
    public init(cache: SnapshotCache, preferences: some DisplayPreferencesStore, reporting: ReportingSetting,
                removeAllData: @escaping RemoveAllData, report: @escaping Report) {
        self.cache = cache
        self.preferences = preferences
        self.reporting = reporting
        self.removeAll = removeAllData
        self.report = report
    }

    public var isReportingEnabled: Bool { reporting.isEnabled }

    /// Signals ``changes()``; call after the cache was written outside this source.
    public func notifyChanged() { broadcaster.send() }

    /// The cache, or an empty snapshot when there is none yet.
    public func current() async throws -> SnapshotFile { cache.read() ?? SnapshotFile() }

    public func changes() -> AsyncStream<Void> { broadcaster.stream() }

    public func requestRefresh(userInitiated: Bool) async throws {
        await report(.refresh(userInitiated: userInitiated))
        notifyChanged()
    }

    public func setThisDeviceName(_ name: String?) async {
        var p = preferences.load()
        p.thisDeviceName = name
        preferences.save(p)
        await report(.userRefresh)  // W8: the new name is written right away
        notifyChanged()
    }

    public func remove(_ id: DeviceID) async throws {
        let cache = self.cache
        try await Task.detached {  // `update` blocks on NSFileCoordinator
            try cache.update { $0.devices.removeAll { $0.id == id || $0.accessory?.parentDeviceID == id } }
        }.value
        notifyChanged()
    }

    public func removeAllData() async throws {
        try await removeAll()
        notifyChanged()
    }

    /// Turns reporting back on; the app restarts its reporter, which reports `.launch`.
    public func resumeReporting() async {
        reporting.setEnabled(true)
        notifyChanged()
    }
}
