// iPhone composition root, local-only for now (owner decision M; NET-004 before the hub
// client lands): UIDeviceBatteryReader → BatteryReporter → LocalOnlySyncService → App Group
// SnapshotCache, read by the UI-001 store and the Widgets-iOS extension. No CloudKit and no
// push: the free Personal Team has neither (SETUP.md). The Mac hub client (NET-003) plugs in
// behind the same `BatterySyncing` seam later; nothing above the seam changes.
import BackgroundTasks
import Foundation
import LevelsModel
import LevelsReaders
import LevelsSync
import LevelsUI
import Observation
import Synchronization
import WidgetKit
import os

@MainActor @Observable final class AppModel {
    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "app")

    /// One per process, shared by the scene and the App Intent (RPT-001 Design, RPT-002).
    static let shared = AppModel()

    let store: DeviceListStore
    /// UI-002 R9: the detail a `levels://device/<uuid>` URL asked for.
    var path: [DeviceID] = []
    /// `levels://settings`.
    var showsSettings = false
    /// RPT-002 R8: "Not now" on the hint card, kept across launches.
    var hintDismissed: Bool {
        didSet { groupDefaults.set(hintDismissed, forKey: ShortcutsHint.dismissedKey) }
    }

    @ObservationIgnored let reporter: BatteryReporter
    @ObservationIgnored let reportLog: ReportLog
    @ObservationIgnored let groupDefaults: UserDefaults
    @ObservationIgnored private let local: LocalOnlySyncService
    @ObservationIgnored private let sync: any BatterySyncing
    @ObservationIgnored private let reporting: ReportingSetting
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false

    private init() {
        UIDeviceBatteryReader.enableMonitoring()  // RPT-001 R1: before any read
        let group = LevelsAppConfig.appGroupID
        let cache: SnapshotCache
        if let group, let shared = SnapshotCache(appGroupID: group) {
            cache = shared
        } else {
            // No App Group: keep working from the app's own container; widgets then see nothing.
            Self.logger.error("App Group \(group ?? "<missing>", privacy: .public) unavailable; using the app container")
            cache = SnapshotCache(directory: URL.applicationSupportDirectory)
        }
        Self.logger.notice("Snapshot cache at \(cache.fileURL.path, privacy: .public)")
        groupDefaults = group.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        hintDismissed = groupDefaults.bool(forKey: ShortcutsHint.dismissedKey)
        let preferences = UserDefaultsDisplayPreferencesStore(suiteName: group)
        let reporting = ReportingSetting(suiteName: group)  // SYNC-001 R15a, survives relaunch
        let relay = ChangeRelay()
        let local = LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: {
            WidgetCenter.shared.reloadAllTimelines()  // SYNC-001 R8a, coalesced by the service
            Self.logger.notice("Requested widget reload")
            relay.fire()
        })
        let sync = LoggingSync(base: local, cacheURL: cache.fileURL, onReport: { relay.fire() })
        let identity = CachingIdentity(KeychainDeviceIdentity(service: LevelsAppConfig.keychainService,
                                                              accessGroup: LevelsAppConfig.keychainAccessGroup))
        let log = ReportLog(suiteName: group)  // RPT-001 R10: rpt.lastReport
        let reporter = BatteryReporter(reader: UIDeviceBatteryReader(), sync: sync, kind: .iphone,
                                       identity: identity, preferences: preferences, log: log, reporting: reporting)
        let source = PhoneSnapshotSource(
            base: SnapshotCacheSource(cache: cache, preferences: preferences, reporting: reporting,
                                      removeAllData: { try await local.removeAllData() }) { reason in
                await reporter.report(reason: reason)
            },
            reporter: reporter, sync: sync,
            onDisplayPreferencesChanged: { await local.displayPreferencesChanged() })
        relay.set { source.notifyChanged() }

        self.local = local
        self.sync = sync
        self.reporting = reporting
        self.identity = identity
        self.reporter = reporter
        self.reportLog = log
        store = DeviceListStore(source: source, preferences: preferences)
    }

    /// Launch (RPT-001 R4, R5). Runs once per process, when the first scene appears.
    func start() async {
        guard !started else { return }
        started = true
        await local.start()
        do {  // make sure the device ID exists before reporting (ADR-0007)
            let id = try identity.currentDeviceID()
            Self.logger.notice("Device ID \(id?.recordName ?? "unavailable", privacy: .public)")
        } catch {
            Self.logger.error("Device ID lookup failed: \(String(describing: error), privacy: .public)")
        }
        tasks.append(Task { await self.store.start() })
        if reporting.isEnabled {
            await reporter.start()  // `.launch`, then UIDevice change events while running (R4, R5)
        } else {
            Self.logger.notice("Reporting is off (Remove all my data); reporter not started")
        }
    }

    /// R4: every time the scene becomes `.active`: report `.foreground` and reload (UI-002 R3).
    func becameActive() {
        Task { await store.refreshOnForeground() }
        WidgetCenter.shared.reloadAllTimelines()  // free while in the foreground (ADR-0017)
    }

    /// R6: every time the scene goes to the background.
    func enteredBackground() {
        BackgroundRefresh.schedule()
    }

    /// R7: the `BGAppRefreshTask` handler. SwiftUI cancels the task when the system expires it.
    nonisolated func backgroundRefresh() async {
        Self.logger.notice("Background refresh started")
        let reporter = await MainActor.run { self.reporter }
        await reporter.report(reason: .backgroundRefresh)
        BackgroundRefresh.schedule()
        Self.logger.notice("Background refresh finished\(Task.isCancelled ? " (expired)" : "", privacy: .public)")
    }

    /// `levels://` routing (UI-002 R9). An unknown device ID opens the list.
    func handle(_ url: URL) {
        Self.logger.notice("Open URL \(url.absoluteString, privacy: .public)")
        switch LevelsAppConfig.route(url) {
        case .device(let id)?:
            showsSettings = false
            path = [id]
        case .list?:
            showsSettings = false
            path = []
        case .settings?:
            showsSettings = true
        case nil:
            break
        }
    }

    /// UI-002 edge case: a detail whose device is gone (or an unknown deep-link ID) pops back.
    func dropMissingDetails() {
        guard store.state != .loading else { return }
        let known = Set((store.rows + store.oldRows).map(\.id))
        if path.contains(where: { !known.contains($0) }) { path = path.filter(known.contains) }
    }

    /// RPT-002 R8.
    func showsShortcutsHint(now: Date = .now) -> Bool {
        ShortcutsHint.isVisible(lastAppIntentReport: reportLog.lastReport(.appIntent), dismissed: hintDismissed, now: now)
    }
}

// MARK: - Background refresh (RPT-001 R6, R7)

enum BackgroundRefresh {
    /// `<bundle id>.battery-refresh`, listed in `BGTaskSchedulerPermittedIdentifiers`.
    static let identifier = "\(Bundle.main.bundleIdentifier ?? "com.levels").battery-refresh"
    /// R6: earliest 30 minutes ahead.
    static let earliestDelay: TimeInterval = 30 * 60

    /// Submits (or replaces) the pending request. Errors are logged; the next background
    /// move tries again.
    static func schedule(now: Date = .now) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(earliestDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppModel.logger.notice("Scheduled \(identifier, privacy: .public) for \(request.earliestBeginDate!, privacy: .public)")
        } catch {
            AppModel.logger.error("Scheduling background refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Wiring helpers (same shape as the Mac app's; ADR-0003 keeps wiring in the targets)

/// Late-bound "cache changed" signal: the source is built after the sync it listens to.
final class ChangeRelay: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)
    func set(_ a: @escaping @Sendable () -> Void) { action.withLock { $0 = a } }
    func fire() { action.withLock { $0 }?() }
}

/// Forwards to the real sync, logs each report (verification) and signals the UI to reload.
struct LoggingSync: BatterySyncing {
    let base: any BatterySyncing
    /// Debug builds log the file after each report, so a device run can be checked from the log.
    let cacheURL: URL
    let onReport: @Sendable () -> Void
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "reporting")

    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        let outcome = await base.report(readings, reason: reason)
        for d in readings {
            Self.logger.notice("""
                Report \(reason.rawValue, privacy: .public): \(d.name, privacy: .private) \
                level=\(d.level.map(String.init) ?? "none", privacy: .public) \
                charging=\(d.isCharging) pluggedIn=\(d.isPluggedIn.map(String.init) ?? "nil", privacy: .public) \
                lowPower=\(d.isLowPowerMode ?? false) → \(String(describing: outcome), privacy: .public)
                """)
        }
        #if DEBUG
        if let data = try? Data(contentsOf: cacheURL), let json = String(data: data, encoding: .utf8) {
            Self.logger.notice("snapshot.json (\(data.count) bytes): \(json, privacy: .private)")  // holds names (ADR-0019 rule 3)
        }
        #endif
        onReport()
        return outcome
    }

    var status: SyncStatus { get async { await base.status } }

    func refresh(_ reason: RefreshReason) async -> Bool { await base.refresh(reason) }
}

/// Caches the Keychain ID once read, so each report doesn't query the Keychain.
final class CachingIdentity: DeviceIdentityProviding {
    private let base: any DeviceIdentityProviding
    private let cached = Mutex<DeviceID?>(nil)
    init(_ base: any DeviceIdentityProviding) { self.base = base }

    func currentDeviceID() throws -> DeviceID? {
        if let id = cached.withLock({ $0 }) { return id }
        let id = try base.currentDeviceID()
        cached.withLock { $0 = id }
        return id
    }
}

/// The local-only source plus what ``SnapshotCacheSource`` leaves to the app: a refresh also
/// asks sync to refresh, and Remove all my data stops the reporter until reporting is turned
/// back on (SYNC-001 R15a). NET-004's `HubSnapshotSource` replaces it when the hub client lands.
final class PhoneSnapshotSource: DeviceSnapshotSource {
    let base: SnapshotCacheSource
    let reporter: BatteryReporter
    let sync: any BatterySyncing
    let onDisplayPreferencesChanged: @Sendable () async -> Void

    init(base: SnapshotCacheSource, reporter: BatteryReporter, sync: any BatterySyncing,
         onDisplayPreferencesChanged: @escaping @Sendable () async -> Void) {
        self.base = base
        self.reporter = reporter
        self.sync = sync
        self.onDisplayPreferencesChanged = onDisplayPreferencesChanged
    }

    var isReportingEnabled: Bool { base.isReportingEnabled }
    func displayPreferencesChanged() async { await onDisplayPreferencesChanged() }

    func notifyChanged() { base.notifyChanged() }
    func current() async throws -> SnapshotFile { try await base.current() }
    func changes() -> AsyncStream<Void> { base.changes() }

    /// UI-002 R2/R3: report (`.userRefresh` or `.foreground`), then `refresh(.userPull / .foreground)`.
    func requestRefresh(userInitiated: Bool) async throws {
        try await base.requestRefresh(userInitiated: userInitiated)
        await sync.refresh(.refresh(userInitiated: userInitiated))
    }

    func setThisDeviceName(_ name: String?) async {
        await base.setThisDeviceName(name)
        WidgetCenter.shared.reloadAllTimelines()  // UI-002 R10
    }

    func remove(_ id: DeviceID) async throws {
        try await base.remove(id)
        WidgetCenter.shared.reloadAllTimelines()  // UI-002 R10
    }

    /// Stops the reporter and waits for its in-flight report, then removes under the sync
    /// service's gate (which also turns reporting off). On failure the reporter runs again.
    func removeAllData() async throws {
        await reporter.stop()
        await reporter.waitUntilIdle()
        do {
            try await base.removeAllData()
        } catch {
            AppModel.logger.error("Remove all data failed: \(String(describing: error), privacy: .public)")
            await reporter.start()
            throw error
        }
        AppModel.logger.notice("Removed all data; reporting is off")
    }

    /// Turns the setting back on, then starts the reporter, whose start reports `.launch` once.
    func resumeReporting() async {
        await base.resumeReporting()
        await reporter.start()
        AppModel.logger.notice("Reporting resumed")
    }
}
