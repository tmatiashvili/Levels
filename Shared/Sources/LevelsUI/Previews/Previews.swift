import LevelsModel
import SwiftUI

// Previews required by UI-001 Tests: every State, light/dark, default and .accessibility3,
// stale, low, charging and no-battery rows, grouped AirPods.

private struct StorePreview: View {
    let snapshot: SnapshotFile
    var showsOldDevices = true
    @State private var store: DeviceListStore?

    var body: some View {
        Group {
            if let store { DeviceList(store: store, showsOldDevices: showsOldDevices) } else { ProgressView() }
        }
        .task {
            let s = PreviewFixtures.store(snapshot)
            store = s
            await s.start()
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}

#Preview("Loaded") { StorePreview(snapshot: PreviewFixtures.loaded) }
#Preview("Loaded, dark") { StorePreview(snapshot: PreviewFixtures.loaded).preferredColorScheme(.dark) }
#Preview("Loaded, accessibility3") {
    StorePreview(snapshot: PreviewFixtures.loaded).dynamicTypeSize(.accessibility3)
}
#Preview("Empty") { StorePreview(snapshot: PreviewFixtures.empty) }
#Preview("Only this device") { StorePreview(snapshot: PreviewFixtures.onlyThisDevice) }
#Preview("No iCloud") { StorePreview(snapshot: PreviewFixtures.noICloud) }
#Preview("Sync error, dark") { StorePreview(snapshot: PreviewFixtures.syncError).preferredColorScheme(.dark) }
#Preview("Local Mac, popover") { StorePreview(snapshot: PreviewFixtures.localMac, showsOldDevices: false) }
#Preview("Loading") { EmptyStateView(state: .loading).frame(width: 320, height: 200) }

private func previewRows() -> [DeviceRowModel] {
    DeviceRows(devices: PreviewFixtures.loaded.devices, thisDeviceID: PreviewFixtures.iPhoneID,
               preferences: DisplayPreferences(), now: PreviewFixtures.now).rows
}

#Preview("Rows: charging, low, stale, no battery, AirPods") {
    List(previewRows()) { DeviceRow(row: $0, now: PreviewFixtures.now) }
        .frame(width: 360, height: 420)
}
#Preview("Rows, accessibility3, dark") {
    List(previewRows()) { DeviceRow(row: $0, now: PreviewFixtures.now) }
        .dynamicTypeSize(.accessibility3)
        .preferredColorScheme(.dark)
        .frame(width: 360, height: 700)
}
#Preview("Gauges") {
    HStack(spacing: 16) {
        BatteryRing(level: 62, isCharging: true, isLow: false)
        BatteryRing(level: 18, isCharging: false, isLow: true)
        BatteryBar(level: 81, isCharging: false, isLow: false).frame(width: 80)
        BatteryBar(level: 15, isCharging: false, isLow: true, style: .accessory).frame(width: 80)
    }
    .padding()
}
