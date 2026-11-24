import Foundation
import LevelsModel
import Synchronization

/// DEMO-001: the list source while demo mode is on. Serves ``SampleDevices/snapshot(now:)``,
/// read fresh on every ``current()`` so ages look live (R2). Never touches the App Group cache
/// or the network (R5): rename is kept in memory, Remove and Remove all my data refuse.
///
/// Pair it with an ``InMemoryDisplayPreferencesStore`` so Hide and Rename don't change the real
/// display preferences (R4).
public final class DemoSnapshotSource: DeviceSnapshotSource {
    public enum DemoError: LocalizedError, Equatable {
        case notInDemo
        public var errorDescription: String? { String(localized: "Exit sample devices first.", bundle: .module) }
    }

    private let now: @Sendable () -> Date
    private let thisDeviceName = Mutex<String?>(nil)
    private let broadcaster = ChangeBroadcaster()

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func current() async throws -> SnapshotFile {
        var file = SampleDevices.snapshot(now: now())
        if let name = thisDeviceName.withLock({ $0 }),
           let i = file.devices.firstIndex(where: { $0.id == SampleDevices.iPhoneID }) {
            file.devices[i].name = name
        }
        return file
    }

    public func changes() -> AsyncStream<Void> { broadcaster.stream() }

    /// Nothing to fetch; the reload that follows recomputes the ages.
    public func requestRefresh(userInitiated: Bool) async throws {}

    public func setThisDeviceName(_ name: String?) async {
        thisDeviceName.withLock { $0 = name }
        broadcaster.send()
    }

    public func remove(_ id: DeviceID) async throws { throw DemoError.notInDemo }
    public func removeAllData() async throws { throw DemoError.notInDemo }
    public func resumeReporting() async {}
    public var isReportingEnabled: Bool { true }
}
