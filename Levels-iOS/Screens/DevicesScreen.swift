// UI-002 R1–R3, R9: the Devices screen. The list itself is UI-001's shared `DeviceList`.
import AppIntents
import LevelsModel
import LevelsUI
import SwiftUI

struct DevicesScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceListStore.self) private var store
    @State private var showsGuide = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            DeviceList(store: store, onPairAgain: { model.showsConnect = true }) { row in model.path.append(row.id) }
                .refreshable { await store.refresh() }  // R2: `.userRefresh`, spinner ends within 15 s
                .safeAreaInset(edge: .top) {
                    if store.state == .notPaired {  // NET-004 R1
                        ConnectMacCard { model.showsConnect = true }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    } else if model.showsShortcutsHint() {  // RPT-002 R8
                        ShortcutsHintCard(onShowGuide: { showsGuide = true },
                                          onDismiss: { withAnimation { model.hintDismissed = true } })
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                }
                .navigationTitle("Levels")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.showsSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: DeviceID.self) { id in
                    DeviceDetailScreen(id: id)
                }
        }
        .sheet(isPresented: $model.showsSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $model.showsConnect) {  // NET-004 R2, R3
            ConnectMacFlowView(flow: model.makeConnectFlow())
        }
        .sheet(isPresented: $showsGuide) {
            NavigationStack { ShortcutsGuideView(showsDone: true) }
        }
        .onChange(of: store.rows) { model.dropMissingDetails() }
        .onChange(of: store.state) { model.dropMissingDetails() }
    }
}

/// RPT-002 "In-app hint": top of the device list until an automation run is seen or dismissed.
struct ShortcutsHintCard: View {
    let onShowGuide: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Keep this iPhone up to date").font(.headline)
            } icon: {
                Image(systemName: "bolt.badge.clock").foregroundStyle(.tint)
            }
            Text("iOS pauses Levels in the background. Add a few Shortcuts automations so this iPhone's battery stays current in Levels and its widgets. Takes 3 minutes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var buttons: some View {
        Button("Show me how", action: onShowGuide)
            .buttonStyle(.borderedProminent)
        ShortcutsLink()
            .shortcutsLinkStyle(.automaticOutline)
        Button("Not now", action: onDismiss)
            .buttonStyle(.borderless)
    }
}

#Preview("Hint card") {
    ShortcutsHintCard(onShowGuide: {}, onDismiss: {})
        .padding()
}
