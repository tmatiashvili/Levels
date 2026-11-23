// MAC-001 composition root (local-only, owner decision K): IOKitBatteryReader →
// BatteryReporter → LocalOnlySyncService → App Group SnapshotCache, read by the UI-001 store
// and the Widgets-Mac extension. MAC-003: MacAccessoryReader → AccessoryReporter feeds the
// same sync with the connected accessories. No CloudKit container and no push registration: the free
// Personal Team has no iCloud or push entitlement (SETUP.md).
import AppKit
import Foundation
import LevelsModel
import LevelsReaders
import LevelsSync
import LevelsUI
import Observation
import Synchronization
import WidgetKit
import os

@MainActor @Observable final class MacAppModel {
    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "app")

    let store: DeviceListStore
    let loginItem: LoginItemController
    /// The App Group `UserDefaults` (menu-bar mode, display preferences).
    @ObservationIgnored let groupDefaults: UserDefaults
    /// R5: set by `applicationShouldHandleReopen`; the device window opens Settings and clears it.
    var settingsRequested = false
    /// UI-004 R14: the row a `levels://device/<uuid>` URL asked for.
    var highlighted: DeviceID?

    @ObservationIgnored let reporter: BatteryReporter
    /// MAC-003: connected accessories (IOKit HID + system_profiler), parent = this Mac.
    @ObservationIgnored let accessories: AccessoryReporter
    @ObservationIgnored let sync: any BatterySyncing
    @ObservationIgnored private let local: LocalOnlySyncService
    @ObservationIgnored private let reporting: ReportingSetting
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastPopoverRefresh: Date?
    @ObservationIgnored private var started = false

    init() {
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
        let reporter = BatteryReporter(reader: IOKitBatteryReader(), sync: sync, kind: .mac,
                                       identity: identity, preferences: preferences,
                                       log: ReportLog(suiteName: group), reporting: reporting)
        let accessories = AccessoryReporter(reader: MacAccessoryReader(), sync: sync,
                                            parentID: { (try? identity.currentDeviceID()) ?? nil },
                                            reporting: reporting)
        let source = MacSnapshotSource(
            base: SnapshotCacheSource(cache: cache, preferences: preferences, reporting: reporting,
                                      removeAllData: { try await local.removeAllData() }) { reason in
                await reporter.report(reason: reason)
            },
            reporter: reporter, accessories: accessories, sync: sync,
            onDisplayPreferencesChanged: { await local.displayPreferencesChanged() })
        relay.set { source.notifyChanged() }

        self.local = local
        self.reporting = reporting
        self.sync = sync
        self.identity = identity
        self.reporter = reporter
        self.accessories = accessories
        store = DeviceListStore(source: source, preferences: preferences)
        loginItem = LoginItemController(service: MainAppLoginService())
    }

    /// R6, R7, R10. Runs once.
    func start() async {
        guard !started else { return }
        started = true
        await local.start()
        loginItem.registerOnFirstLaunchIfNeeded()  // R6
        do {  // R7: make sure the device ID exists before reporting
            let id = try identity.currentDeviceID()
            Self.logger.notice("Device ID \(id?.recordName ?? "unavailable", privacy: .public)")
        } catch {
            Self.logger.error("Device ID lookup failed: \(String(describing: error), privacy: .public)")
        }
        tasks.append(Task { await self.store.start() })
        if reporting.isEnabled {
            await reporter.start()  // MAC-002 R6a launch report, IOPS changes, 30-min heartbeat
            await accessories.start()  // MAC-003: launch scan, HID + Bluetooth connect/disconnect, 5/15-min poll
        } else {
            Self.logger.notice("Reporting is off (Remove all my data); reporters not started")
        }
        observePowerSourceForAccessories()
        observeSleepAndWake()  // reporters must skip these while reporting is off
        // R10a (network reachable → refresh) and R11 (15-min fallback fetch) have nothing to
        // fetch without iCloud; LocalOnlySyncService.refresh is a cache re-read, so neither runs.
    }

    /// R10: sleep reports without waiting; wake reports, then refreshes.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        let reporter = reporter, sync = sync, accessories = accessories
        tasks.append(Task {
            for await _ in center.notifications(named: NSWorkspace.willSleepNotification).map({ _ in () }) {
                Self.logger.notice("Will sleep")
                Task { await reporter.report(reason: .sleep) }
            }
        })
        tasks.append(Task {
            for await _ in center.notifications(named: NSWorkspace.didWakeNotification).map({ _ in () }) {
                Self.logger.notice("Did wake")
                await reporter.report(reason: .wake)
                await accessories.report(reason: .wake)  // ADR-0015: re-scan on wake
                await sync.refresh(.wake)
            }
        })
    }

    /// ADR-0015: re-scan accessories when the power source changes (charger in or out).
    /// IOPS also fires on every 1 % step, so only power-state changes trigger a scan.
    private func observePowerSourceForAccessories() {
        let accessories = accessories
        tasks.append(Task {
            var last: BatteryReading.PowerState?
            for await reading in IOKitBatteryReader().changes() {
                defer { last = reading.powerState }
                guard let last, last != reading.powerState else { continue }
                await accessories.report(reason: .batteryChange)
            }
        })
    }

    /// UI-004 R7 / MAC-001 R11: opening the popover refreshes at most once a minute.
    func popoverOpened() {
        let now = Date()
        if let last = lastPopoverRefresh, now.timeIntervalSince(last) < 60 { return }
        lastPopoverRefresh = now
        Task { await store.refreshOnForeground() }
    }

    /// The refresh button and ⌘R (UI-004 R6, R7): `.userRefresh`.
    func userRefresh() {
        Task { await store.refresh() }
    }

    /// `levels://` routing (MAC-001 R2a, R5; UI-004 R14).
    func handle(_ url: URL) -> LevelsAppConfig.Route? {
        let route = LevelsAppConfig.route(url)
        Self.logger.notice("Open URL \(url.absoluteString, privacy: .public)")
        switch route {
        case .device(let id)?: highlighted = id
        case .list?: highlighted = nil
        case .settings?: settingsRequested = true
        case nil: break
        }
        return route
    }
}

// MARK: - Wiring helpers

/// Late-bound "cache changed" signal: the source is built after the sync it listens to.
final class ChangeRelay: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)
    func set(_ a: @escaping @Sendable () -> Void) { action.withLock { $0 = a } }
    func fire() { action.withLock { $0 }?() }
}

/// Forwards to the real sync, logs each report (verification) and signals the UI to reload.
struct LoggingSync: BatterySyncing {
    let base: any BatterySyncing
    /// Debug builds log the file after each report: the App Group container is protected
    /// from other apps (Terminal included), so this is how a run is checked.
    let cacheURL: URL
    let onReport: @Sendable () -> Void
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "reporting")

    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        let outcome = await base.report(readings, reason: reason)
        for d in readings {
            Self.logger.notice("""
                Report \(reason.rawValue, privacy: .public): \(d.name, privacy: .private)\
                \(d.accessory.map { " [\($0.kind.rawValue) \($0.component.rawValue)]" } ?? "", privacy: .public) \
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

/// The local-only source plus the parts the shared ``SnapshotCacheSource`` leaves to the app:
/// a refresh also asks sync to refresh, and Remove all my data stops the reporter until
/// reporting is turned back on (SYNC-001 R15a shape).
final class MacSnapshotSource: DeviceSnapshotSource {
    let base: SnapshotCacheSource
    let reporter: BatteryReporter
    let accessories: AccessoryReporter
    let sync: any BatterySyncing
    let onDisplayPreferencesChanged: @Sendable () async -> Void

    init(base: SnapshotCacheSource, reporter: BatteryReporter, accessories: AccessoryReporter, sync: any BatterySyncing,
         onDisplayPreferencesChanged: @escaping @Sendable () async -> Void) {
        self.base = base
        self.reporter = reporter
        self.accessories = accessories
        self.sync = sync
        self.onDisplayPreferencesChanged = onDisplayPreferencesChanged
    }

    var isReportingEnabled: Bool { base.isReportingEnabled }
    func displayPreferencesChanged() async { await onDisplayPreferencesChanged() }

    func notifyChanged() { base.notifyChanged() }
    func current() async throws -> SnapshotFile { try await base.current() }
    func changes() -> AsyncStream<Void> { base.changes() }

    /// MAC-003: a refresh also scans accessories (⌘R always, popover open at most once a minute).
    func requestRefresh(userInitiated: Bool) async throws {
        try await base.requestRefresh(userInitiated: userInitiated)
        await accessories.refresh(userInitiated: userInitiated)
        await sync.refresh(.refresh(userInitiated: userInitiated))
    }

    func setThisDeviceName(_ name: String?) async { await base.setThisDeviceName(name) }
    func remove(_ id: DeviceID) async throws { try await base.remove(id) }

    /// Stops both reporters and waits for their in-flight reports, then removes under the sync
    /// service's gate (which also turns reporting off). On failure the reporter runs again.
    func removeAllData() async throws {
        await reporter.stop()
        await accessories.stop()
        await reporter.waitUntilIdle()
        await accessories.waitUntilIdle()
        do {
            try await base.removeAllData()
        } catch {
            MacAppModel.logger.error("Remove all data failed: \(String(describing: error), privacy: .public)")
            await reporter.start()
            await accessories.start()
            throw error
        }
        MacAppModel.logger.notice("Removed all data; reporting is off")
    }

    /// Turns the setting back on, then starts the reporter, whose start reports `.launch` once.
    func resumeReporting() async {
        await base.resumeReporting()
        await reporter.start()
        await accessories.start()
        MacAppModel.logger.notice("Reporting resumed")
    }
}
