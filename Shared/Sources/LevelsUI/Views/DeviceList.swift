import LevelsModel
import SwiftUI

/// The shared device list (UI-001): banner, rows in R1 order, footers and, optionally, the
/// "Old devices" section with Remove (R14, UI-002 R11). A `List`, for free swipe actions on iOS.
/// Platform shells add navigation, toolbar and `.refreshable`.
public struct DeviceList: View {
    @Bindable var store: DeviceListStore
    let showsOldDevices: Bool
    let onSelect: ((DeviceRowModel) -> Void)?
    let highlighted: DeviceID?
    let onPairAgain: () -> Void

    @State private var renaming = false
    @State private var newName = ""

    /// - Parameters:
    ///   - showsOldDevices: the Mac popover passes `false`; old devices go to its Settings (UI-004 R9).
    ///   - onSelect: tap action (iPhone pushes the detail); `nil` = rows aren't tappable.
    ///   - highlighted: a row to scroll into view and highlight (Mac device window, UI-004 R14).
    public init(store: DeviceListStore, showsOldDevices: Bool = true, highlighted: DeviceID? = nil,
                onPairAgain: @escaping () -> Void = {},
                onSelect: ((DeviceRowModel) -> Void)? = nil) {
        self.onPairAgain = onPairAgain
        self.store = store
        self.showsOldDevices = showsOldDevices
        self.highlighted = highlighted
        self.onSelect = onSelect
    }

    public var body: some View {
        TimelineView(.everyMinute) { context in
          ScrollViewReader { proxy in
            List {
                if SyncStatusBanner.isVisible(state: store.state, isReportingOff: store.isReportingOff) {
                    Section {
                        SyncStatusBanner(state: store.state, isReportingOff: store.isReportingOff,
                                         onDismiss: { store.dismissSyncError() },
                                         onResumeReporting: { Task { await store.resumeReporting() } },
                                         onPairAgain: onPairAgain)
                    }
                }
                Section {
                    ForEach(store.rows) { row in
                        rowView(row, now: context.date)
                            .id(row.id)
                            .listRowBackground(row.id == highlighted ? Color.accentColor.opacity(0.18) : nil)
                    }
                } footer: {
                    if store.state == .onlyThisDevice { EmptyStateView(state: .onlyThisDevice) }
                }
                if showsOldDevices && !store.oldRows.isEmpty {
                    OldDevicesSection(store: store, now: context.date)
                }
            }
            .overlay {
                if store.rows.isEmpty && (store.state == .loading || store.state == .empty) {
                    EmptyStateView(state: store.state)
                }
            }
            .animation(.default, value: store.rows)
            .onAppear { scroll(proxy) }
            .onChange(of: highlighted) { scroll(proxy) }
            .onChange(of: store.rows) { scroll(proxy) }
          }
        }
        #if !os(watchOS)
        .alert(Text("Rename this device", bundle: .module), isPresented: $renaming) {
            TextField(text: $newName) { Text("Name", bundle: .module) }
            Button { Task { await store.renameThisDevice(to: newName) } } label: { Text("Save", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Leave empty to use the default name.", bundle: .module)
        }
        #endif
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlighted, store.rows.contains(where: { $0.id == highlighted }) else { return }
        withAnimation { proxy.scrollTo(highlighted, anchor: .center) }
    }

    @ViewBuilder private func rowView(_ row: DeviceRowModel, now: Date) -> some View {
        let content = DeviceRow(row: row, now: now)
        Group {
            if let onSelect {
                Button { onSelect(row) } label: { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        #if !os(watchOS)
        .contextMenu {
            if store.canRename(row) {
                Button {
                    newName = row.name
                    renaming = true
                } label: { Label { Text("Rename…", bundle: .module) } icon: { Image(systemName: "pencil") } }
            }
            Button { store.setHidden(row.id, true) } label: {
                Label { Text("Hide", bundle: .module) } icon: { Image(systemName: "eye.slash") }
            }
        }
        #endif
    }
}

/// "Old devices" (R14, UI-002 R11): collapsed by default; each row has Remove with a confirmation.
/// This device never appears here. Also used by the Mac Settings window (UI-004 R9).
public struct OldDevicesSection: View {
    @Bindable var store: DeviceListStore
    let now: Date
    @State private var isExpanded = false
    @State private var pendingRemoval: DeviceRowModel?

    public init(store: DeviceListStore, now: Date = .now) {
        self.store = store
        self.now = now
    }

    public var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if store.isHubMode {  // NET-004 R8: the Mac's full snapshot would add them back
                    ForEach(store.oldRows) { row in DeviceRow(row: row, now: now) }
                    Text("Remove old devices on your Mac.", bundle: .module)
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                ForEach(store.oldRows) { row in
                    HStack {
                        DeviceRow(row: row, now: now)
                        Button(role: .destructive) { pendingRemoval = row } label: { Text("Remove", bundle: .module) }
                            .buttonStyle(.borderless)
                    }
                    #if os(iOS)
                    .swipeActions {
                        Button(role: .destructive) { pendingRemoval = row } label: { Text("Remove", bundle: .module) }
                    }
                    #endif
                }
                }
            } label: {
                Text("Old devices", bundle: .module)
            }
        }
        .confirmationDialog(
            Text(Self.removeTitle(pendingRemoval?.name ?? "")),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { row in
            Button(role: .destructive) {
                Task { try? await store.remove(row.id) }
            } label: { Text("Remove", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        }
    }

    /// "Remove <name>? It will come back if that device runs Levels again." (UI-002 R11)
    nonisolated public static func removeTitle(_ name: String) -> String {
        loc("Remove \(name)? It will come back if that device runs Levels again.")
    }
}
