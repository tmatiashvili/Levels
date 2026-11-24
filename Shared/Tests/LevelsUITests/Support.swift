import Foundation
import LevelsModel
import Synchronization
@testable import LevelsUI

let now = Date(timeIntervalSince1970: 1_800_000_000)
let minute: TimeInterval = 60
let hour: TimeInterval = 3600
let day: TimeInterval = 86_400
let en = Locale(identifier: "en_US")

func id(_ n: Int) -> DeviceID {
    DeviceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
}

func device(_ id: DeviceID, _ kind: DeviceKind, _ name: String, level: Int?, charging: Bool = false,
            lowPower: Bool? = nil, age: TimeInterval = 5 * minute) -> DeviceBattery {
    DeviceBattery(id: id, name: name, kind: kind, level: level, isCharging: charging, isLowPowerMode: lowPower,
                  updatedAt: now - age)
}

let airPodsGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

func airPod(_ component: AccessoryComponent, level: Int?, name: String = "AirPods Pro", age: TimeInterval = 5 * minute,
            group: UUID = airPodsGroup, parent: DeviceID = id(2)) -> DeviceBattery {
    DeviceBattery(id: .accessory(key: "\(group)", component: component), name: name, kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: parent, kind: .airpods, groupID: group, component: component),
                  level: level, isCharging: false, updatedAt: now - age)
}

func rows(_ devices: [DeviceBattery], this: DeviceID? = nil,
          preferences: DisplayPreferences = DisplayPreferences()) -> DeviceRows {
    DeviceRows(devices: devices, thisDeviceID: this, preferences: preferences, now: now)
}

struct TestError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

/// Scripted ``DeviceSnapshotSource`` that records every call.
final class FakeSource: DeviceSnapshotSource {
    struct Calls: Equatable {
        var refresh: [Bool] = []
        var reportReasons: [ReportReason] = []
        var rename: [String?] = []
        var removed: [DeviceID] = []
        var removeAll = 0
        var resume = 0
        var preferencesChanged = 0
    }

    private let state: Mutex<(snapshot: SnapshotFile, calls: Calls, readError: Bool, refreshError: Bool, hangs: Bool)>
    private let broadcaster = ChangeBroadcaster()

    private let reportingEnabled: Bool

    init(_ snapshot: SnapshotFile, readError: Bool = false, refreshError: Bool = false, hangs: Bool = false,
         reportingEnabled: Bool = true) {
        state = Mutex((snapshot, Calls(), readError, refreshError, hangs))
        self.reportingEnabled = reportingEnabled
    }

    var calls: Calls { state.withLock { $0.calls } }

    func set(_ body: (inout SnapshotFile) -> Void, notify: Bool = true) {
        state.withLock { body(&$0.snapshot) }
        if notify { broadcaster.send() }
    }

    func setReadError(_ on: Bool) { state.withLock { $0.readError = on } }

    func current() async throws -> SnapshotFile {
        let (file, fails) = state.withLock { ($0.snapshot, $0.readError) }
        if fails { throw TestError() }
        return file
    }

    func changes() -> AsyncStream<Void> { broadcaster.stream() }

    func requestRefresh(userInitiated: Bool) async throws {
        let (fails, hangs) = state.withLock {
            $0.calls.refresh.append(userInitiated)
            $0.calls.reportReasons.append(.refresh(userInitiated: userInitiated))
            return ($0.refreshError, $0.hangs)
        }
        if hangs { try await Task.sleep(for: .seconds(3600)) }
        if fails { throw TestError() }
    }

    func setThisDeviceName(_ name: String?) async { state.withLock { $0.calls.rename.append(name) } }

    func remove(_ id: DeviceID) async throws {
        state.withLock {
            $0.calls.removed.append(id)
            $0.snapshot.devices.removeAll { $0.id == id }
        }
    }

    func removeAllData() async throws {
        state.withLock {
            $0.calls.removeAll += 1
            $0.snapshot.devices.removeAll()
        }
    }

    func resumeReporting() async { state.withLock { $0.calls.resume += 1 } }

    var isReportingEnabled: Bool { reportingEnabled }

    func displayPreferencesChanged() async { state.withLock { $0.calls.preferencesChanged += 1 } }
}

@MainActor
func makeStore(_ source: FakeSource, preferences: DisplayPreferences = DisplayPreferences(),
               timeout: Duration = .seconds(15)) -> (DeviceListStore, InMemoryDisplayPreferencesStore) {
    let prefs = InMemoryDisplayPreferencesStore(preferences)
    return (DeviceListStore(source: source, preferences: prefs, now: { now }, refreshTimeout: timeout), prefs)
}

/// Yields until `condition` holds (or about 2 s pass).
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
