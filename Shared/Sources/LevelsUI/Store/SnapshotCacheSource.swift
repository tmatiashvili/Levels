import Foundation
import LevelsModel

/// A local-only ``DeviceSnapshotSource`` over SYNC-002's ``SnapshotCache`` (no iCloud, no push):
/// the Mac-first build, where the only writer is this device's own reporter.
///
/// `report` asks the reporter for a reading with the given reason (it writes the cache through
/// its `BatterySyncing`); the app calls ``notifyChanged()`` after any other cache write.
public final class SnapshotCacheSource: DeviceSnapshotSource {
    public typealias Report = @Sendable (ReportReason) async -> Void

    private let cache: SnapshotCache
    private let preferences: any DisplayPreferencesStore
    private let report: Report
    private let broadcaster = ChangeBroadcaster()

    public init(cache: SnapshotCache, preferences: some DisplayPreferencesStore, report: @escaping Report) {
        self.cache = cache
        self.preferences = preferences
        self.report = report
    }

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
        let cache = self.cache
        try await Task.detached { try cache.reset() }.value
        notifyChanged()
    }

    public func resumeReporting() async {
        await report(.launch)
        notifyChanged()
    }
}
