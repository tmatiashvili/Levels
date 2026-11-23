// UI-004 R1–R10: the menu-bar label, the popover content and the device window (MAC-001 R2a).
import AppKit
import LevelsModel
import LevelsUI
import SwiftUI

/// The menu-bar label (UI-004 R1–R5): a template symbol plus text, monochrome.
struct MenuBarLabel: View {
    let store: DeviceListStore
    let mode: MenuBarMode

    // No TimelineView here: inside a MenuBarExtra label it re-renders the status item in a
    // loop. The label updates whenever the store changes (at least every 30-min heartbeat).
    var body: some View {
        let content = MenuBarLabelModel.content(rows: store.rows, mode: mode, now: .now)
        HStack(spacing: 3) {
            Image(systemName: content.symbol)
            if let text = content.text { Text(text).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// The popover (UI-004 R6): banner + list (this Mac first) + footer. Width 320, height up to 480.
struct MenuBarPopover: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        DevicesPanel(highlighted: nil)
            .frame(width: 320)
            .frame(height: PopoverLayout.height(rows: model.store.rows, state: model.store.state,
                                                isReportingOff: model.store.isReportingOff,
                                                isStacked: DeviceRow.isStacked(dynamicTypeSize)))
            .onAppear { model.popoverOpened() }  // UI-004 R7
    }
}

/// The device window (MAC-001 R2a): the popover content at window size, opened by
/// `levels://` URLs; it also opens Settings when asked (R5).
struct DeviceWindowView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// HIS-001: the selected device's history is pushed on top of the list.
    @State private var path: [DeviceID] = []

    var body: some View {
        let ideal = Self.idealSize(height: PopoverLayout.height(rows: model.store.rows, state: model.store.state,
                                                                isReportingOff: model.store.isReportingOff))
        NavigationStack(path: $path) {
            DevicesPanel(highlighted: model.highlighted, onSelect: { path.append($0.id) })  // HIS-001 R8
                .navigationDestination(for: DeviceID.self) { id in historyDetail(id) }
        }
        .frame(minWidth: Self.minSize.width, idealWidth: ideal.width, maxWidth: 560,
               minHeight: Self.minSize.height, idealHeight: ideal.height)
        .onOpenURL { url in
            _ = model.handle(url)
            NSApp.activate()
            openSettingsIfRequested()
        }
        .onAppear {
            NSApp.activate()
            openSettingsIfRequested()
        }
        .onChange(of: model.settingsRequested) { openSettingsIfRequested() }
    }

    /// Smallest useful window: one row plus the footer, popover width (UI-004 R6).
    static let minSize = CGSize(width: 320, height: 160)

    /// First-open size: the popover's size for the current rows, a little wider for the
    /// window chrome (UI-004 R6, MAC-001 R2a). Later opens keep the user's size.
    static func idealSize(height popoverHeight: CGFloat) -> CGSize {
        CGSize(width: 360, height: max(minSize.height, popoverHeight))
    }

    /// HIS-001 R8: a row's 7-day chart; the row stays live, so a new report reloads it.
    @ViewBuilder private func historyDetail(_ id: DeviceID) -> some View {
        if let row = model.store.rows.first(where: { $0.id == id }) {
            DeviceHistoryView(row: row) { [model] ids in await model.historySamples(ids) }
                .frame(minWidth: 360, minHeight: 320)
                .navigationTitle(row.name)
        } else {
            Text("This device is no longer in the list.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// R5: Settings opens only from SwiftUI, once per request.
    private func openSettingsIfRequested() {
        guard model.settingsRequested else { return }
        model.settingsRequested = false
        openSettings()
        NSApp.activate()
    }
}

/// List and footer shared by the popover and the device window.
struct DevicesPanel: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let highlighted: DeviceID?
    /// HIS-001: the device window opens a row's history; the popover passes `nil` (R11).
    var onSelect: ((DeviceRowModel) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            DeviceList(store: model.store, showsOldDevices: false, highlighted: highlighted, onSelect: onSelect)  // old devices: Settings (R9)
                .scrollContentBackground(.hidden)
                .environment(\.isLocalOnly, true)  // owner decision K: this build has no other devices
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.everyMinute) { context in
                if let newest = model.store.rows.map({ $0.readingDate(now: context.date) }).max() {
                    Text("Updated \(AgeFormatting.text(readingDate: newest, now: context.date))")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button { model.userRefresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)  // UI-004 R6, R7
            .disabled(model.store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Menu {
                Button("Settings…") { showSettings() }.keyboardShortcut(",", modifiers: .command)
                Button("Hidden devices…") { showSettings() }
                Button("About Levels") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit Levels") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)  // MAC-001 R3, R12
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}
