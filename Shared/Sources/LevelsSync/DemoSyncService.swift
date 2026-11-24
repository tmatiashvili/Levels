import Foundation
import LevelsModel
import Synchronization

/// DEMO-001 R5, R6: the sync service while demo mode is on. It holds no cache, no transport
/// and no pairing: reports are dropped (counted for tests), `refresh` has nothing to fetch.
public final class DemoSyncService: BatterySyncing {
    private let dropped = Mutex(0)

    public init() {}

    /// Reports dropped so far.
    public var droppedReports: Int { dropped.withLock { $0 } }

    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        dropped.withLock { $0 += 1 }
        return .skipped
    }

    public var status: SyncStatus { get async { .localOnly } }

    @discardableResult
    public func refresh(_ reason: RefreshReason) async -> Bool { true }
}

/// DEMO-001 Design: sits between the reporter and the real sync (the hub). While
/// ``DemoModeSetting/isOn`` every call goes to the ``DemoSyncService``; otherwise to `real`.
/// The flag is read per call, so Exit takes effect on the next report.
public struct DemoAwareSync: BatterySyncing {
    public let real: any BatterySyncing
    public let demo: DemoSyncService
    public let mode: DemoModeSetting

    public init(real: any BatterySyncing, demo: DemoSyncService = DemoSyncService(), mode: DemoModeSetting) {
        self.real = real
        self.demo = demo
        self.mode = mode
    }

    private var active: any BatterySyncing { mode.isOn ? demo : real }

    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        await active.report(readings, reason: reason)
    }

    public var status: SyncStatus { get async { await active.status } }

    @discardableResult
    public func refresh(_ reason: RefreshReason) async -> Bool { await active.refresh(reason) }
}
