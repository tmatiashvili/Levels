// DEMO-001: "Try with sample devices". The demo list runs beside the real one: the real
// store, cache, pairing and preferences stay as they are, the reporter's reports go to
// DemoSyncService (DemoAwareSync in AppModel's init), and nothing reaches the network.
import LevelsModel
import LevelsUI
import WidgetKit

extension AppModel {
    /// R1: the Connect card and the Connect screen.
    func enterDemo() {
        guard !isDemo else { return }
        Self.logger.notice("Demo mode on")
        demoMode.setOn(true)
        isDemo = true
        showsConnect = false
        path = []
        startDemoStore()
        Task { await hub.stopLiveUpdates() }  // R5: no long-poll in demo mode
        WidgetCenter.shared.reloadAllTimelines()  // R10
    }

    /// R8: back to the real list, with the real pairing as it was.
    func exitDemo() async {
        guard isDemo else { return }
        Self.logger.notice("Demo mode off")
        demoMode.setOn(false)
        demoTask?.cancel()
        demoTask = nil
        isDemo = false
        demoStore = nil
        path = []
        WidgetCenter.shared.reloadAllTimelines()  // R10
        _ = await reporter.report(reason: .userRefresh)  // R6: the Mac gets this iPhone's battery again
        await hub.refresh(.foreground)
        if isActive { await hub.startLiveUpdates() }
        await refreshPairingState()
    }

    /// The sample list: its own source and in-memory preferences, so Hide and Rename never
    /// change the real ones (R4, R5).
    func startDemoStore() {
        let store = DeviceListStore(source: DemoSnapshotSource(), preferences: InMemoryDisplayPreferencesStore(),
                                    isHubMode: true)
        configureStore(store, isDemo: true)
        demoStore = store
        demoTask?.cancel()
        demoTask = Task { await store.start() }
    }

    /// Levels Pro hook (DEMO-001 R9): the one place both lists are set up, the real one at
    /// launch and every demo one. When ProGate lands, set `store.gate` here (and whenever the
    /// entitlement changes, for `realStore` and `demoStore`); for the demo list use
    /// `freeMacID: SampleDevices.macID`, so the sample MacBook Pro is the free Mac. The
    /// widget's gate does the same while `DemoModeSetting.isOn`.
    func configureStore(_ store: DeviceListStore, isDemo: Bool) {}
}
