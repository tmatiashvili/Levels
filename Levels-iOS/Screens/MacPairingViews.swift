// NET-004 R1–R3, R7: the Connect card, the Connect flow and Settings ▸ Mac.
import LevelsModel
import LevelsNet
import LevelsUI
import SwiftUI
import UIKit

/// R1: replaces the device list while not paired; this iPhone's row shows below it.
struct ConnectMacCard: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Connect to your Mac").font(.headline)
            } icon: {
                Image(systemName: "macbook.and.iphone").foregroundStyle(.tint)
            }
            Text("Levels shows your Mac's battery and accessories when your iPhone is on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect", action: onConnect)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// R2, R3 and the wait for the Mac (confirmation number seam, see ``MacPairer``).
struct ConnectMacFlowView: View {
    @State var flow: ConnectMacFlowModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect to your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if case .connected = flow.step {} else {
                            Button("Cancel") { flow.stop(); dismiss() }
                        }
                    }
                }
        }
        .onDisappear { flow.stop() }
        .confirmationDialog(Text("Replace \(flow.replaceName ?? "")?"),
                            isPresented: Binding(get: { flow.replaceName != nil }, set: { if !$0 { flow.replaceName = nil } }),
                            titleVisibility: .visible) {
            Button("Replace") {
                flow.replaceName = nil
                flow.submit(replacing: true)
            }
            Button("Cancel", role: .cancel) { flow.replaceName = nil }
        } message: {
            Text("This iPhone can get levels from one Mac.")
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .explain:
            VStack(spacing: 20) {
                Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Next, iOS asks to find devices on your network. Levels uses this only to reach your Mac.")
                    .multilineTextAlignment(.center)
                Button("Continue") { flow.continueTapped() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxHeight: .infinity)
        case .choose:
            chooseForm
        case .waitingForMac(let confirmation):
            VStack(spacing: 16) {
                ProgressView()
                if let confirmation {
                    Text("Check that your Mac shows the same number:")
                        .multilineTextAlignment(.center)
                    Text(PairingText.grouped(confirmation))
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .accessibilityLabel(Text(confirmation.map(String.init).joined(separator: " ")))
                    Text("Then tap They match on your Mac.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Connecting to your Mac…").foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { flow.cancelWaiting() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxHeight: .infinity)
        case .connected(let name):
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green).accessibilityHidden(true)
                Text("Connected to \(name)").font(.headline)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxHeight: .infinity)
        }
    }

    private var chooseForm: some View {
        Form {
            Section {
                if flow.isLocalNetworkDenied {
                    Text("Local Network access is off for Levels. Turn it on in Settings ▸ Levels.")
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                } else if flow.hubs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for your Mac…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(flow.hubs) { hub in
                        Button {
                            flow.selectedTag = hub.tag
                        } label: {
                            HStack {
                                Label(hub.name, systemImage: "laptopcomputer")
                                Spacer()
                                if flow.selectedTag == hub.tag {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(flow.selectedTag == hub.tag ? .isSelected : [])
                    }
                }
            } header: {
                Text("Your Mac")
            } footer: {
                Text("On your Mac, open Levels ▸ Settings ▸ iPhone ▸ Pair iPhone.")
            }

            Section {
                TextField("6-digit code", text: $flow.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced))
                    .focused($codeFocused)
                if let error = flow.errorText {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            } header: {
                Text("Code shown on your Mac")
            }

            Section {
                Button("Connect") { flow.submit() }
                    .disabled(!flow.canSubmit)
            }
        }
        .onAppear { codeFocused = true }
    }
}

/// R7: Settings ▸ Mac.
struct MacSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsForget = false
    /// Its own sheet: Settings is itself a sheet, so the root's Connect sheet can't show over it.
    @State private var connecting = false

    var body: some View {
        Section {
            if let mac = model.pairedMac {
                LabeledContent("Mac", value: mac.hubName)
                LabeledContent("Last update") {
                    if let at = model.macLastContact {
                        Text(AgeFormatting.text(readingDate: at, now: .now))
                    } else {
                        Text("Not yet")
                    }
                }
                Button("Pair again") { connecting = true }
                Button("Forget this Mac", role: .destructive) { confirmsForget = true }
            } else {
                Button {
                    connecting = true
                } label: {
                    Label("Connect to your Mac", systemImage: "macbook.and.iphone")
                }
            }
        } header: {
            Text("Mac")
        } footer: {
            if model.pairedMac == nil {
                Text("Levels shows your Mac's battery and accessories when your iPhone is on the same Wi-Fi.")
            }
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { Task { await model.forgetMac() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone stops getting levels from \(model.pairedMac?.hubName ?? "your Mac").")
        }
        .task { await model.refreshPairingState() }
        .sheet(isPresented: $connecting, onDismiss: { Task { await model.refreshPairingState() } }) {
            ConnectMacFlowView(flow: model.makeConnectFlow())
        }
    }
}
