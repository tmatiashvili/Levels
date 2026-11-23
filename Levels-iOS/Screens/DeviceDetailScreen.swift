// UI-002 R4–R7: device detail. Rename is offered for this iPhone only; Hide for every device.
import LevelsModel
import LevelsUI
import SwiftUI

struct DeviceDetailScreen: View {
    let id: DeviceID
    @Environment(DeviceListStore.self) private var store
    @State private var renaming = false
    @State private var newName = ""

    private var row: DeviceRowModel? {
        (store.rows + store.oldRows + store.hiddenRows).first { $0.id == id }
    }

    var body: some View {
        Group {
            if let row {
                TimelineView(.everyMinute) { context in
                    content(row, now: context.date)
                }
            } else {
                ContentUnavailableView("Device not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been removed."))
            }
        }
        .navigationTitle(row?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename this iPhone", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await store.renameThisDevice(to: DetailText.renameValue(newName)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the default name.")
        }
    }

    private func content(_ row: DeviceRowModel, now: Date) -> some View {
        let stale = row.freshness(at: now) == .stale
        let reading = row.readingDate(now: now)
        return List {
            Section {
                VStack(spacing: 12) {
                    if let level = row.level {
                        ZStack {
                            BatteryRing(level: level, isCharging: row.showsChargingBolt(at: now), isLow: row.isLow, size: 140)
                            VStack(spacing: 2) {
                                Text(RowText.percent(level))
                                    .font(.largeTitle.weight(.semibold))
                                    .monospacedDigit()
                                if row.isLow {
                                    Text(RowText.low()).font(.subheadline.bold()).foregroundStyle(.red)
                                } else if row.showsChargingBolt(at: now) {
                                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .opacity(stale ? 0.5 : 1)  // UI-001 R6
                    } else {
                        DeviceSymbol(row: row).font(.system(size: 56))
                    }
                    HStack(spacing: 6) {
                        DeviceSymbol(row: row)
                        Text(row.name).font(.title3.weight(.semibold))
                    }
                    if row.isThisDevice {
                        Text("This iPhone").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
            }

            if stale {
                Section {
                    Label {
                        Text("This device hasn't reported for \(DetailText.staleAge(now.timeIntervalSince(reading))). It may be asleep, off or offline.")
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LabeledContent("Power", value: chargingText(row))
                LabeledContent("Low Power Mode", value: row.isLowPowerMode ? String(localized: "On") : String(localized: "Off"))
                LabeledContent("Updated") {
                    VStack(alignment: .trailing) {
                        Text(reading, format: .dateTime.hour().minute())
                        Text(AgeFormatting.text(readingDate: reading, now: now))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Type", value: typeText(row))
            }

            Section {
                if store.canRename(row) {
                    Button("Rename") {
                        newName = row.name
                        renaming = true
                    }
                }
                if store.hiddenRows.contains(where: { $0.id == row.id }) {
                    Button("Show in Levels") { store.setHidden(row.id, false) }
                } else {
                    Button("Hide from Levels") { store.setHidden(row.id, true) }  // R7; the screen pops
                }
            }
        }
    }

    private func chargingText(_ row: DeviceRowModel) -> String {
        switch DetailText.charging(level: row.level, isCharging: row.isCharging, isPluggedIn: row.isPluggedIn) {
        case .charging: String(localized: "Charging")
        case .pluggedInNotCharging: String(localized: "Plugged in, not charging")
        case .notCharging: String(localized: "Not charging")
        case .noBattery: String(localized: "Plugged in · no battery")
        }
    }

    private func typeText(_ row: DeviceRowModel) -> String {
        switch row.kind {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .mac: "Mac"
        case .watch: "Apple Watch"
        case .accessory: String(localized: "Accessory")
        case .other: String(localized: "Device")
        }
    }
}

#Preview("Detail") {
    let now = Date()
    let id = DeviceID(UUID())
    let source = InMemorySnapshotSource(SnapshotFile(ownDeviceID: id, devices: [
        DeviceBattery(id: id, name: "iPhone", kind: .iphone, level: 62, isCharging: true, isPluggedIn: true,
                      isLowPowerMode: false, updatedAt: now - 120),
    ]))
    let store = DeviceListStore(source: source, preferences: InMemoryDisplayPreferencesStore())
    return NavigationStack { DeviceDetailScreen(id: id) }
        .environment(store)
        .task { await store.reload() }
}
