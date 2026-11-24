import Foundation
import LevelsModel
import Synchronization

/// A ``DeviceSnapshotSource`` that keeps the snapshot in memory: previews, demos, and local
/// builds that feed readings in themselves (call ``update(_:)``).
public final class InMemorySnapshotSource: DeviceSnapshotSource {
    private let snapshot: Mutex<SnapshotFile>
    private let broadcaster = ChangeBroadcaster()

    public init(_ snapshot: SnapshotFile = SnapshotFile()) { self.snapshot = Mutex(snapshot) }

    /// Changes the snapshot and signals ``changes()``.
    public func update(_ body: @Sendable (inout SnapshotFile) -> Void) {
        snapshot.withLock { body(&$0) }
        broadcaster.send()
    }

    public func current() async throws -> SnapshotFile { snapshot.withLock { $0 } }
    public func changes() -> AsyncStream<Void> { broadcaster.stream() }
    public func requestRefresh(userInitiated: Bool) async throws {}

    public func setThisDeviceName(_ name: String?) async {
        update { file in
            guard let own = file.ownDeviceID, let i = file.devices.firstIndex(where: { $0.id == own }) else { return }
            file.devices[i].name = DefaultDeviceName.resolved(kind: file.devices[i].kind, thisDeviceName: name)
        }
    }

    public func remove(_ id: DeviceID) async throws {
        update { $0.devices.removeAll { $0.id == id || $0.accessory?.parentDeviceID == id } }
    }

    public func removeAllData() async throws { update { $0.devices.removeAll() } }
    public func resumeReporting() async {}
    public var isReportingEnabled: Bool { true }
}
