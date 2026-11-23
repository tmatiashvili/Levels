// UI-002 R8, R12 in hub mode: the NET-004 R7 "Mac" section, R9 Remove all my data, R10 About.
import LevelsModel
import LevelsNet
import LevelsUI
import SwiftUI

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmsRemoveAll = false
    @State private var removeError: String?

    private var thisRow: DeviceRowModel? {
        (store.rows + store.hiddenRows).first(where: \.isThisDevice)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("This iPhone") {
                    Button {
                        newName = thisRow?.name ?? ""
                        renaming = true
                    } label: {
                        LabeledContent("Name", value: thisRow?.name ?? DefaultDeviceName.current(kind: .iphone))
                    }
                    .foregroundStyle(.primary)
                    .disabled(store.thisDeviceID == nil)
                }

                MacSettingsSection()

                Section {
                    NavigationLink {
                        ShortcutsGuideView(showsDone: false)
                    } label: {
                        HStack {
                            Text("Set up Shortcuts automation")
                            Spacer()
                            if ShortcutsHint.isSetUp(lastAppIntentReport: model.reportLog.lastReport(.appIntent), now: .now) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityLabel("Set up")
                            }
                        }
                    }
                } header: {
                    Text("Keep this iPhone up to date")
                } footer: {
                    if let line = lastBackgroundReportLine() { Text(line) }
                }

                Section("Hidden devices") {
                    if store.hiddenRows.isEmpty {
                        Text("No hidden devices").foregroundStyle(.secondary)
                    }
                    ForEach(store.hiddenRows) { row in
                        HStack {
                            DeviceSymbol(row: row)
                            Text(row.name)
                            Spacer()
                            Button("Unhide") { store.setHidden(row.id, false) }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Data") {
                    Button("Remove all my data", role: .destructive) { confirmsRemoveAll = true }
                        .disabled(store.isReportingOff)
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Data stays on your devices and your home network. No analytics.")  // NET-004 R10
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename this iPhone", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { Task { await store.renameThisDevice(to: DetailText.renameValue(newName)) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave empty to use the default name.")
            }
            .confirmationDialog("Remove all my data?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
                Button("Remove all my data", role: .destructive) {
                    Task {
                        do {
                            try await store.removeAllData()
                            dismiss()
                        } catch is HubError {
                            // NET-004 R9: the Mac must be reachable; nothing was deleted.
                            removeError = String(localized: "Connect to the same Wi-Fi as your Mac to remove data there.")
                        } catch {
                            removeError = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if model.pairedMac != nil {  // NET-004 R9
                    Text("This deletes the levels stored on this iPhone and this iPhone's battery on your Mac. Your Mac keeps its own levels.")
                } else {
                    Text("This deletes the battery levels stored on this iPhone and stops reporting. You can turn reporting back on from the list.")
                }
            }
            .alert("Couldn't remove your data", isPresented: Binding(get: { removeError != nil },
                                                                   set: { if !$0 { removeError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was deleted. \(removeError ?? "")")
            }
        }
    }

    /// RPT-002 Design: "Last background report: 12 min ago (Shortcuts)".
    private func lastBackgroundReportLine(now: Date = .now) -> String? {
        let candidates: [(ReportReason, String)] = [
            (.appIntent, String(localized: "Shortcuts")),
            (.backgroundRefresh, String(localized: "background refresh")),
        ]
        guard let (date, via) = candidates
            .compactMap({ reason, via in model.reportLog.lastReport(reason).map { ($0, via) } })
            .max(by: { $0.0 < $1.0 })
        else { return nil }
        let age = AgeFormatting.text(readingDate: date, now: now)
        return String(localized: "Last background report: \(age) (\(via))")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview("Settings") {
    SettingsSheet()
        .environment(AppModel.shared)
        .environment(AppModel.shared.store)
}
