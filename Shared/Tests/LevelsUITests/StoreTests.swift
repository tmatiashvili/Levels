import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

@MainActor
@Suite("UI-001 DeviceListStore")
struct StoreTests {
    let me = device(id(1), .mac, "MacBook Pro", level: 45, charging: true)
    let phone = device(id(2), .iphone, "iPhone", level: 62)

    func snapshot(_ devices: [DeviceBattery], own: DeviceID? = id(1), status: SyncStatus? = .idle) -> SnapshotFile {
        SnapshotFile(ownDeviceID: own, syncStatus: status, devices: devices)
    }

    @Test func R11_loadingBeforeFirstRead() {
        let (store, _) = makeStore(FakeSource(snapshot([me])))
        #expect(store.state == .loading)
    }

    @Test func AC8_noDevicesIsEmpty() async {
        let (store, _) = makeStore(FakeSource(snapshot([], own: nil)))
        await store.reload()
        #expect(store.state == .empty)
        #expect(store.rows.isEmpty)
    }

    @Test func R11_onlyThisDevice() async {
        let (store, _) = makeStore(FakeSource(snapshot([me])))
        await store.reload()
        #expect(store.state == .onlyThisDevice)
    }

    @Test func R11_loaded() async {
        let (store, _) = makeStore(FakeSource(snapshot([me, phone])))
        await store.reload()
        #expect(store.state == .loaded)
        #expect(store.rows.map(\.id) == [me.id, phone.id])
    }

    @Test(arguments: [SyncStatus.signedOut, .restricted])
    func AC9_signedOutShowsRowsAndICloudBanner(status: SyncStatus) async {
        let (store, _) = makeStore(FakeSource(snapshot([me, phone], status: status)))
        await store.reload()
        #expect(store.rows.count == 2)
        #expect(store.state == .noICloud)
        #expect(SyncStatusBanner.isVisible(state: store.state, isReportingOff: store.isReportingOff))
    }

    @Test func localOnlySnapshotWithoutSyncStatusHasNoBanner() async {
        let (store, _) = makeStore(FakeSource(snapshot([me, phone], status: nil)))
        await store.reload()
        #expect(store.state == .loaded)
    }

    @Test func localOnlyStatusShowsNoBanner() async {
        for devices in [[me], [me, phone]] {
            let (store, _) = makeStore(FakeSource(snapshot(devices, status: .localOnly)))
            await store.reload()
            #expect(store.state == (devices.count == 1 ? .onlyThisDevice : .loaded))
            #expect(!SyncStatusBanner.isVisible(state: store.state, isReportingOff: store.isReportingOff))
        }
    }

    @Test func firstReadThrowsGivesSyncErrorAndEmptyList() async {
        let (store, _) = makeStore(FakeSource(snapshot([me]), readError: true))
        await store.reload()
        #expect(store.state == .syncError("boom"))
        #expect(store.rows.isEmpty)
    }

    @Test func cachedOfflineStatusShowsDismissibleSyncError() async {
        let (store, _) = makeStore(FakeSource(snapshot([me, phone], status: .offline(lastFetchAt: nil))))
        await store.reload()
        #expect(store.state == .syncError("Offline"))
        #expect(store.rows.count == 2)
        store.dismissSyncError()
        #expect(store.state == .loaded)
    }

    @Test func AC10_changeUpdatesRowsWithoutRefresh() async {
        let source = FakeSource(snapshot([me, phone]))
        let (store, _) = makeStore(source)
        let task = Task { await store.start() }
        defer { task.cancel() }
        #expect(await eventually { store.rows.first { $0.id == phone.id }?.level == 62 })
        source.set { $0.devices[$0.devices.firstIndex { $0.id == id(2) }!].level = 30 }
        #expect(await eventually { store.rows.first { $0.id == phone.id }?.level == 30 })
        #expect(source.calls.refresh.isEmpty)
    }

    @Test func R12_refreshIsUserRefreshWithSpinner() async {
        let source = FakeSource(snapshot([me]))
        let (store, _) = makeStore(source)
        await store.refresh()
        #expect(source.calls.refresh == [true])
        #expect(source.calls.reportReasons == [.userRefresh])
        #expect(!store.isRefreshing)
    }

    @Test func R12_foregroundRefreshIsForeground() async {
        let source = FakeSource(snapshot([me]))
        let (store, _) = makeStore(source)
        await store.refreshOnForeground()
        #expect(source.calls.reportReasons == [.foreground])
        #expect(RefreshReason.refresh(userInitiated: true) == .userPull)
        #expect(RefreshReason.refresh(userInitiated: false) == .foreground)
    }

    @Test func refreshErrorKeepsRowsAndShowsSyncError() async {
        let source = FakeSource(snapshot([me, phone]), refreshError: true)
        let (store, _) = makeStore(source)
        await store.reload()
        await store.refresh()
        #expect(store.state == .syncError("boom"))
        #expect(store.rows.count == 2)
    }

    @Test func refreshSpinnerEndsWhenSourceHangs() async {
        let source = FakeSource(snapshot([me]), hangs: true)
        let (store, _) = makeStore(source, timeout: .milliseconds(50))
        await store.refresh()
        #expect(!store.isRefreshing)
        #expect(store.state == .syncError("Timed out"))
    }

    @Test func AC5_renameThisDevice() async {
        let source = FakeSource(snapshot([me, phone]))
        let (store, _) = makeStore(source)
        await store.reload()
        let mine = store.rows.first { $0.isThisDevice }!
        let other = store.rows.first { !$0.isThisDevice }!
        #expect(store.canRename(mine))
        #expect(!store.canRename(other))

        await store.renameThisDevice(to: "  Work Mac ")
        #expect(source.calls.rename == ["Work Mac"])

        source.set { $0.devices[$0.devices.firstIndex { $0.id == id(1) }!].name = "Work Mac" }
        await store.reload()
        let renamed = store.rows.first { $0.isThisDevice }!
        #expect(renamed.name == "Work Mac")
        #expect(RowText.accessibilityLabel(for: renamed, now: now, locale: en).hasPrefix("Work Mac, "))
    }

    @Test func R3_emptyRenameResets() async {
        let source = FakeSource(snapshot([me]))
        let (store, _) = makeStore(source)
        await store.reload()
        await store.renameThisDevice(to: "   ")
        await store.renameThisDevice(to: nil)
        #expect(source.calls.rename == [nil, nil])
    }

    @Test func renameDisabledWhenOwnIDUnknown() async {
        let source = FakeSource(snapshot([me, phone], own: nil))
        let (store, _) = makeStore(source)
        await store.reload()
        #expect(store.rows.allSatisfy { !store.canRename($0) })
        await store.renameThisDevice(to: "X")
        #expect(source.calls.rename.isEmpty)
    }

    @Test func AC4_setHiddenSavesAndRemovesRow() async {
        let (store, prefs) = makeStore(FakeSource(snapshot([me, phone])))
        await store.reload()
        store.setHidden(phone.id, true)
        #expect(!store.rows.contains { $0.id == phone.id })
        #expect(store.hiddenRows.map(\.id) == [phone.id])
        #expect(prefs.load().hidden == [phone.id])
        store.setHidden(phone.id, false)
        #expect(store.rows.contains { $0.id == phone.id })
    }

    @Test func setHiddenKeepsARenameSavedBySource() async {
        let (store, prefs) = makeStore(FakeSource(snapshot([me, phone])))
        prefs.save(DisplayPreferences(thisDeviceName: "Work Mac"))
        store.setHidden(phone.id, true)
        #expect(prefs.load() == DisplayPreferences(hidden: [phone.id], thisDeviceName: "Work Mac"))
    }

    @Test func R14_removeOldDevice() async throws {
        let old = device(id(3), .mac, "Old Mac", level: 50, age: 40 * day)
        let source = FakeSource(snapshot([me, old]))
        let (store, _) = makeStore(source)
        await store.reload()
        #expect(store.oldRows.map(\.id) == [old.id])
        try await store.remove(old.id)
        #expect(source.calls.removed == [old.id])
        #expect(store.oldRows.isEmpty)
    }

    @Test func removeGroupedRowRemovesEveryComponent() async throws {
        let pods = [airPod(.left, level: 40, age: 40 * day), airPod(.case, level: 80, age: 40 * day)]
        let source = FakeSource(snapshot([me] + pods))
        let (store, _) = makeStore(source)
        await store.reload()
        try await store.remove(DeviceID(airPodsGroup))
        #expect(Set(source.calls.removed) == Set(pods.map(\.id)))
    }

    @Test func thisDeviceCannotBeRemoved() async throws {
        let source = FakeSource(snapshot([me]))
        let (store, _) = makeStore(source)
        await store.reload()
        try await store.remove(me.id)
        #expect(source.calls.removed.isEmpty)
    }

    @Test func removeAllDataThenResume() async throws {
        let source = FakeSource(snapshot([me, phone]))
        let (store, _) = makeStore(source)
        await store.reload()
        try await store.removeAllData()
        #expect(source.calls.removeAll == 1)
        #expect(store.isReportingOff)
        #expect(store.rows.isEmpty)
        await store.resumeReporting()
        #expect(source.calls.resume == 1)
        #expect(!store.isReportingOff)
    }

    /// SYNC-001 R15a: reporting stays off across a relaunch, so a new store starts with the banner.
    @Test func reportingOffIsLoadedFromTheSource() {
        let (store, _) = makeStore(FakeSource(snapshot([me]), reportingEnabled: false))
        #expect(store.isReportingOff)
        let (on, _) = makeStore(FakeSource(snapshot([me])))
        #expect(!on.isReportingOff)
    }

    /// SYNC-001 R8a (lead's call 17): widgets show the hidden set, so hiding asks for a reload.
    @Test func hidingTellsTheSource() async {
        let source = FakeSource(snapshot([me, phone]))
        let (store, _) = makeStore(source)
        await store.reload()
        store.setHidden(phone.id, true)
        #expect(await eventually { source.calls.preferencesChanged == 1 })
    }
}

@Suite("UI-001 display preferences")
struct PreferencesTests {
    @Test func userDefaultsRoundTrip() throws {
        let suite = "levels.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UserDefaultsDisplayPreferencesStore(suiteName: suite)
        #expect(store.load() == DisplayPreferences())
        let p = DisplayPreferences(hidden: [id(1), id(2)], thisDeviceName: "Work Mac")
        store.save(p)
        #expect(UserDefaultsDisplayPreferencesStore(suiteName: suite).load() == p)
        #expect(UserDefaults(suiteName: suite)?.data(forKey: "displayPreferences") != nil)
    }

    @Test func corruptOrPartialDataLoadsDefaults() throws {
        let suite = "levels.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(Data("nope".utf8), forKey: "displayPreferences")
        #expect(UserDefaultsDisplayPreferencesStore(suiteName: suite).load() == DisplayPreferences())
        defaults.set(Data(#"{"thisDeviceName":"X"}"#.utf8), forKey: "displayPreferences")
        #expect(UserDefaultsDisplayPreferencesStore(suiteName: suite).load() == DisplayPreferences(thisDeviceName: "X"))
    }
}

@Suite("Local-only sources")
struct LocalSourceTests {
    @Test func snapshotCacheSourceReportsWithRefreshReasons() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        let mac = device(id(1), .mac, "Mac", level: 50)
        let pod = airPod(.left, level: 40, parent: id(1))
        try cache.update { $0.ownDeviceID = id(1); $0.devices = [mac, pod, device(id(2), .iphone, "P", level: 1)] }

        let reasons = ReasonLog()
        let prefs = InMemoryDisplayPreferencesStore()
        let reporting = ReportingSetting.inMemory()
        let removals = ReasonLog()
        let source = SnapshotCacheSource(cache: cache, preferences: prefs, reporting: reporting,
                                         removeAllData: {
                                             try cache.reset()
                                             reporting.setEnabled(false)
                                             await removals.append(.launch)
                                         }) { await reasons.append($0) }
        try await source.requestRefresh(userInitiated: true)
        try await source.requestRefresh(userInitiated: false)
        await source.setThisDeviceName("Work Mac")
        #expect(await reasons.all == [.userRefresh, .foreground, .userRefresh])
        #expect(prefs.load().thisDeviceName == "Work Mac")

        try await source.remove(id(1))  // the Mac and its accessories
        #expect(try await source.current().devices.map(\.id) == [id(2)])
        try await source.removeAllData()  // goes through sync's removal (R15a)
        #expect(await removals.all.count == 1)
        #expect(try await source.current().devices.isEmpty)
        #expect(!source.isReportingEnabled)

        // Resume only turns the setting back on; the app's reporter start reports `.launch` once.
        await source.resumeReporting()
        #expect(source.isReportingEnabled)
        #expect(await reasons.all == [.userRefresh, .foreground, .userRefresh])
    }

    @MainActor @Test func inMemorySourceDrivesStore() async {
        let source = InMemorySnapshotSource(PreviewFixtures.localMac)
        let store = DeviceListStore(source: source, preferences: InMemoryDisplayPreferencesStore())
        let task = Task { await store.start() }
        defer { task.cancel() }
        #expect(await eventually { store.rows.count == 2 })
        #expect(store.state == .loaded)
        await store.renameThisDevice(to: "Work Mac")
        #expect(store.rows.first?.name == "Work Mac")
    }
}

actor ReasonLog {
    var all: [ReportReason] = []
    func append(_ r: ReportReason) { all.append(r) }
}
