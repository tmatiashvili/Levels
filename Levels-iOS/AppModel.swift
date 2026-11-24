// iPhone composition root in hub mode (owner decision M, NET-003 R1, ADR-0020):
// UIDeviceBatteryReader → BatteryReporter → LocalNetworkSyncService (wrapping
// LocalOnlySyncService) → App Group SnapshotCache, read by the UI-001 store and the Widgets-iOS
// extension. The Mac on the home Wi-Fi is the hub: the iPhone posts its own reading and fetches
// the Mac's snapshot. No CloudKit and no push: the free Personal Team has neither (SETUP.md).
import BackgroundTasks
import Foundation
import LevelsModel
import LevelsNet
import LevelsReaders
import LevelsSync
import LevelsUI
import Network
import Observation
import Synchronization
import WidgetKit
import os

@MainActor @Observable final class AppModel {
    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "app")

    /// One per process, shared by the scene and the App Intent (RPT-001 Design, RPT-002).
    static let shared = AppModel()

    /// The real list (hub mode). ``store`` is the list on screen: the demo list while demo
    /// mode is on (DEMO-001), else this one.
    let realStore: DeviceListStore
    var store: DeviceListStore { isDemo ? (demoStore ?? realStore) : realStore }
    /// DEMO-001 R7: "Try with sample devices" is on (App Group flag, survives relaunch).
    var isDemo: Bool
    /// DEMO-001: the sample-devices list while demo mode is on (AppModel+Demo.swift).
    var demoStore: DeviceListStore? = nil
    /// UI-002 R9: the detail a `levels://device/<uuid>` URL asked for.
    var path: [DeviceID] = []
    /// `levels://settings`.
    var showsSettings = false
    /// NET-004 R1–R3: the Connect flow sheet.
    var showsConnect = false
    /// NET-004 R7: the stored Mac pairing (name only is shown).
    private(set) var pairedMac: HubPairing?
    /// NET-004 R7: "Last update <age>".
    private(set) var macLastContact: Date?
    /// RPT-002 R8: "Not now" on the hint card, kept across launches.
    var hintDismissed: Bool {
        didSet { groupDefaults.set(hintDismissed, forKey: ShortcutsHint.dismissedKey) }
    }

    @ObservationIgnored let reporter: BatteryReporter
    @ObservationIgnored let reportLog: ReportLog
    @ObservationIgnored let groupDefaults: UserDefaults
    @ObservationIgnored private let local: LocalOnlySyncService
    @ObservationIgnored let hub: LocalNetworkSyncService
    @ObservationIgnored private let pairingStore: any ClientPairingStore
    @ObservationIgnored private let preferences: UserDefaultsDisplayPreferencesStore
    @ObservationIgnored private let sync: any BatterySyncing
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored var isActive = false
    @ObservationIgnored let demoMode: DemoModeSetting
    @ObservationIgnored var demoTask: Task<Void, Never>?
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
        let demoMode = DemoModeSetting(suiteName: group)  // DEMO-001 R7
        let relay = ChangeRelay()
        let outbox = HubOutbox()  // NET-003 R2
        let local = LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: {
            WidgetCenter.shared.reloadAllTimelines()  // SYNC-001 R8a, coalesced by the service
            Self.logger.notice("Requested widget reload")
            relay.fire()
        }, onOwnWrite: { outbox.put($0) })
        let identity = CachingIdentity(KeychainDeviceIdentity(service: LevelsAppConfig.keychainService,
                                                              accessGroup: LevelsAppConfig.keychainAccessGroup))
        // NET-002 R8: one item in the shared access group, so the widget can read it (variant B).
        let pairingStore = KeychainClientPairingStore(service: LevelsAppConfig.hubPairingService,
                                                      items: SecKeychainItems(accessGroup: LevelsAppConfig.keychainAccessGroup))
        // The Mac's last address in the App Group: the app and the widget dial it before Bonjour.
        let transport = NWHubTransport(memory: UserDefaultsHubEndpointMemory(suiteName: group))
        let hub = LocalNetworkSyncService(local: local, outbox: outbox, transport: transport,
                                          pairing: pairingStore, identity: identity, cache: cache, etagSuite: group,
                                          onChange: { relay.fire() })
        // DEMO-001 R6: while demo mode is on, reports and refreshes go to DemoSyncService instead.
        let sync = LoggingSync(base: DemoAwareSync(real: hub, mode: demoMode), cacheURL: cache.fileURL,
                               onReport: { relay.fire() })
        let log = ReportLog(suiteName: group)  // RPT-001 R10: rpt.lastReport
        let reporter = BatteryReporter(reader: UIDeviceBatteryReader(), sync: sync, kind: .iphone,
                                       identity: identity, preferences: preferences, log: log, reporting: reporting)
        let source = HubSnapshotSource(
            base: SnapshotCacheSource(cache: cache, preferences: preferences, reporting: reporting,
                                      removeAllData: { try await hub.removeAllData() }) { reason in
                await reporter.report(reason: reason)
            },
            reporter: reporter, sync: sync, hub: hub,
            onDisplayPreferencesChanged: { await local.displayPreferencesChanged() })
        relay.set { source.notifyChanged() }

        self.local = local
        self.hub = hub
        self.pairingStore = pairingStore
        self.preferences = preferences
        self.sync = sync
        self.reporting = reporting
        self.identity = identity
        self.reporter = reporter
        self.reportLog = log
        realStore = DeviceListStore(source: source, preferences: preferences, isHubMode: true)
        self.demoMode = demoMode
        isDemo = demoMode.isOn
        pairedMac = pairingStore.current()
        configureStore(realStore, isDemo: false)
    }

    /// Launch (RPT-001 R4, R5). Runs once per process, when the first scene appears.
    func start() async {
        guard !started else { return }
        started = true
        await hub.start()  // NET-003: `.notPaired` or the cached hub status
        do {  // make sure the device ID exists before reporting (ADR-0007)
            let id = try identity.currentDeviceID()
            Self.logger.notice("Device ID \(id?.recordName ?? "unavailable", privacy: .public)")
        } catch {
            Self.logger.error("Device ID lookup failed: \(String(describing: error), privacy: .public)")
        }
        tasks.append(Task { await self.realStore.start() })
        if isDemo { startDemoStore() }  // DEMO-001 R7: relaunched in demo mode
        if reporting.isEnabled {
            await reporter.start()  // `.launch`, then UIDevice change events while running (R4, R5)
        } else {
            Self.logger.notice("Reporting is off (Remove all my data); reporter not started")
        }
        if !isDemo { await hub.refresh(.launch) }  // NET-003 R6; DEMO-001 R5: no network in demo mode
        await refreshPairingState()
        startPathMonitor()
    }

    /// R4: every time the scene becomes `.active`: report `.foreground` and reload (UI-002 R3);
    /// NET-003 R7 / NET-004 R6: live updates while active.
    func becameActive() {
        isActive = true
        Task {
            await store.refreshOnForeground()  // reports, then `hub.refresh(.foreground)`
            if isActive, !isDemo { await hub.startLiveUpdates() }  // DEMO-001 R5
            await refreshPairingState()
        }
        WidgetCenter.shared.reloadAllTimelines()  // free while in the foreground (ADR-0017)
    }

    /// NET-003 R7: the long-poll stops when the scene leaves `.active`.
    func resignedActive() {
        isActive = false
        Task { await hub.stopLiveUpdates() }
    }

    /// R6: every time the scene goes to the background.
    func enteredBackground() {
        resignedActive()
        BackgroundRefresh.schedule()
        let hub = hub
        Task { await hub.flushWidgetReload() }  // a held reload would die with the suspended process
    }

    /// R7 and NET-003 R8: the `BGAppRefreshTask` handler. Reports, then syncs with the Mac
    /// when it is reachable, within 20 s in total. SwiftUI cancels the task when the system
    /// expires it.
    nonisolated func backgroundRefresh() async {
        Self.logger.notice("Background refresh started")
        let (reporter, hub, demoMode) = await MainActor.run { (self.reporter, self.hub, self.demoMode) }
        let finished = await Self.within(.seconds(20)) {
            await reporter.report(reason: .backgroundRefresh)
            if !demoMode.isOn { await hub.refresh(.backgroundRefresh) }  // DEMO-001 R5
        }
        await hub.flushWidgetReload()  // before iOS suspends the process again
        BackgroundRefresh.schedule()
        Self.logger.notice("Background refresh finished\(finished ? "" : " (20 s limit)", privacy: .public)\(Task.isCancelled ? " (expired)" : "", privacy: .public)")
    }

    /// Runs `work` for at most `limit`; returns whether it finished.
    nonisolated static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Mac pairing (NET-002, NET-004 R1–R3, R7)

    /// A fresh Connect flow.
    func makeConnectFlow() -> ConnectMacFlowModel {
        let identity = identity, preferences = preferences, pairingStore = pairingStore
        return ConnectMacFlowModel(
            browse: { HubBrowser.results() },
            pairer: CodePairer(),
            me: {
                guard let id = try? identity.currentDeviceID() else { return nil }
                let name = DefaultDeviceName.resolved(kind: .iphone, thisDeviceName: preferences.load().thisDeviceName)
                return PairRequestIdentity(deviceID: id, name: name, kind: .iphone)
            },
            existing: { pairingStore.current() },
            save: { [weak self] pairing in
                try pairingStore.save(pairing)
                await self?.didPair()
            })
    }

    private func didPair() async {
        if isDemo { await exitDemo() }  // DEMO-001 R8: a real Mac ends demo mode
        Self.logger.notice("Paired with hub \(self.pairingStore.current()?.hubTag ?? "?", privacy: .public)")
        await hub.didPair()
        if isActive { await hub.startLiveUpdates() }
        await refreshPairingState()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// NET-002 R9.
    func forgetMac() async {
        await hub.forget()
        await refreshPairingState()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refreshPairingState() async {
        pairedMac = pairingStore.current()
        macLastContact = await hub.lastContactAt
    }

    /// NET-003 R6 "network reachable": Wi-Fi becomes satisfied while the app runs.
    private func startPathMonitor() {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let wasSatisfied = PathFlag()
        let hub = hub, demoMode = demoMode
        monitor.pathUpdateHandler = { path in
            let now = path.status == .satisfied
            let before = wasSatisfied.swap(now)
            if now, before == false, !demoMode.isOn {  // DEMO-001 R5
                Self.logger.notice("Wi-Fi reachable; refreshing from the Mac")
                Task { await hub.refresh(.networkReachable) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "levels.path"))
        pathMonitor = monitor
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

/// The last Wi-Fi state the path monitor saw.
final class PathFlag: Sendable {
    private let value = Mutex<Bool?>(nil)
    func swap(_ new: Bool) -> Bool? { value.withLock { old in defer { old = new }; return old } }
}

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

    /// In hub mode `.restricted` means Local Network off, not iCloud: the reporter must not
    /// fail the "Report Battery" intent for it (the reading reached the cache).
    var status: SyncStatus {
        get async {
            let s = await base.status
            return s == .restricted ? .localOnly : s
        }
    }

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

/// NET-004 Design `HubSnapshotSource`: the cache source plus what ``SnapshotCacheSource``
/// leaves to the app. A refresh also asks the hub sync to refresh; Remove all my data deletes
/// this iPhone's record on the Mac first (NET-003 R10) and stops the reporter until reporting
/// is turned back on (SYNC-001 R15a). Single-device Remove happens on the Mac only (R8).
final class HubSnapshotSource: DeviceSnapshotSource {
    enum HubSourceError: LocalizedError {
        case notSupportedInHubMode
        var errorDescription: String? { String(localized: "Remove old devices on your Mac.") }
    }

    let base: SnapshotCacheSource
    let reporter: BatteryReporter
    let sync: any BatterySyncing
    let hub: LocalNetworkSyncService
    let onDisplayPreferencesChanged: @Sendable () async -> Void

    init(base: SnapshotCacheSource, reporter: BatteryReporter, sync: any BatterySyncing, hub: LocalNetworkSyncService,
         onDisplayPreferencesChanged: @escaping @Sendable () async -> Void) {
        self.base = base
        self.reporter = reporter
        self.sync = sync
        self.hub = hub
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

    /// NET-004 R8 (lead's call 26): the Mac's full snapshot would add it back.
    func remove(_ id: DeviceID) async throws {
        throw HubSourceError.notSupportedInHubMode
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
        await hub.resumeReporting()
        await reporter.start()
        AppModel.logger.notice("Reporting resumed")
    }
}
