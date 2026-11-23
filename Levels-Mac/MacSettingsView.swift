// UI-004 R9 + MAC-001 R4: the Settings window.
import AppKit
import LevelsModel
import LevelsUI
import SwiftUI

struct MacSettingsView: View {
    @Environment(MacAppModel.self) private var model
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true  // MAC-001 R4(c)
    @AppStorage(MenuBarMode.key, store: UserDefaults(suiteName: LevelsAppConfig.appGroupID ?? ""))
    private var menuBarMode: MenuBarMode = .lowest
    @State private var name = ""
    @State private var confirmingRemoveAll = false
    @State private var removeError: String?

    var body: some View {
        let store = model.store
        Form {
            Section("This Mac") {
                TextField("Name of this Mac", text: $name, prompt: Text(DefaultDeviceName.current(kind: .mac)))
                    .onSubmit { Task { await store.renameThisDevice(to: name) } }
                    .disabled(store.thisDeviceID == nil)
            }
            Section("Menu bar") {
                Picker("Menu bar shows", selection: $menuBarMode) {
                    Text("Lowest device").tag(MenuBarMode.lowest)
                    Text("Icon only").tag(MenuBarMode.iconOnly)
                }
                Toggle("Show in menu bar", isOn: $showMenuBarItem)
            }
            Section("Login") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.setEnabled($0) }))
                if model.loginItem.requiresApproval {  // MAC-001 R4(b)
                    HStack {
                        Text("Allow Levels in System Settings → Login Items")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { model.loginItem.openLoginItemsSettings() }
                    }
                }
                if let error = model.loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            AlertsSettingsSection(alerts: model.alerts, store: store)  // ALR-001
            Section("Hidden devices") {
                if store.hiddenRows.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(store.hiddenRows) { row in
                    HStack {
                        DeviceRow(row: row)
                        Button("Unhide") { store.setHidden(row.id, false) }.buttonStyle(.borderless)
                    }
                }
            }
            if !store.oldRows.isEmpty {
                OldDevicesSection(store: store)  // UI-004 R9, UI-002 R11
            }
            Section("Data") {
                Button("Remove all my data…", role: .destructive) { confirmingRemoveAll = true }
                Text("Levels keeps battery data on this Mac only. No iCloud, no analytics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: Self.version)
                Button("Quit Levels") { NSApp.terminate(nil) }  // MAC-001 R4(d)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
        .onAppear {
            name = store.preferences.thisDeviceName ?? ""
            model.loginItem.refresh()
        }
        .confirmationDialog("Remove all my data?", isPresented: $confirmingRemoveAll) {
            Button("Remove all my data", role: .destructive) {
                Task {
                    do { try await store.removeAllData() } catch { removeError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // UI-002 R12, adapted: this build keeps no iCloud copy.
            Text("This deletes the battery data Levels keeps on this Mac and stops reporting until you turn it back on.")
        }
        .alert("Couldn't remove data", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK") {}
        } message: {
            Text(removeError ?? "")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
