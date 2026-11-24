// NET-001 R14, R15 and NET-002 R1, R2, R7, R9: Settings ▸ iPhone.
import LevelsModel
import LevelsNet
import SwiftUI

struct HubSettingsSection: View {
    @Bindable var hub: HubServer
    @State private var pairing = false
    @State private var removing: PairedClient?
    @State private var confirmingRemoveAll = false

    var body: some View {
        Section("iPhone") {
            Toggle("Share with iPhone on this Wi-Fi", isOn: $hub.sharingEnabled)
            HStack {
                Text(statusText).foregroundStyle(.secondary)
                if hub.status == .failed {
                    Spacer()
                    Button("Retry") { hub.retry() }
                }
            }
            .font(.callout)
            ForEach(hub.paired) { client in
                HStack {
                    Image(systemName: client.kind == .ipad ? "ipad" : "iphone")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(client.name)
                        lastSeen(client).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { removing = client }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Pair iPhone…") { pairing = true }
                    .disabled(!hub.sharingEnabled || hub.status == .reportingOff)
                Spacer()
                if !hub.paired.isEmpty {
                    Button("Remove all pairings…", role: .destructive) { confirmingRemoveAll = true }
                }
            }
            if hub.showsFirewallHint() {
                Text("If your iPhone can't find this Mac, check System Settings ▸ Network ▸ Firewall ▸ Options and allow Levels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $pairing) { PairingSheet(hub: hub) }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { Task { await hub.remove(id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(removing?.name ?? "This device") will stop seeing this Mac's levels until you pair it again.")
        }
        .confirmationDialog("Remove all pairings?", isPresented: $confirmingRemoveAll) {
            Button("Remove all pairings", role: .destructive) { Task { await hub.removeAllPairings() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every paired iPhone and iPad stops seeing this Mac's levels until you pair it again.")
        }
    }

    private var statusText: String {
        switch hub.status {
        case .sharing: "Sharing on this Wi-Fi as Levels-\(hub.tag)"
        case .starting: "Starting…"
        case .off: "Off"
        case .reportingOff: "Off while reporting is off"
        case .notPaired: "Not sharing: no iPhone paired"
        case .failed: "Couldn't start sharing"
        }
    }

    private func lastSeen(_ client: PairedClient) -> Text {
        guard let seen = client.lastSeenAt else { return Text("Not seen yet") }
        return Text("Last seen \(seen, format: .relative(presentation: .named))")
    }
}

/// NET-002 R1, R2, R6a, R7: the code, the hub name, a countdown, the confirmation number
/// to compare, and the outcome.
struct PairingSheet: View {
    let hub: HubServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair iPhone").font(.headline)
            content
            HStack {
                Spacer()
                Button(isDone ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(isDone ? .defaultAction : .cancelAction)
                if isConfirming {
                    // Call 30: the device gets its key only after this tap.
                    Button("They match") { hub.approvePairing() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { hub.openPairing() }
        .onDisappear { hub.closePairing() }
    }

    private var isDone: Bool {
        if case .paired = hub.pairingState { return true }
        return false
    }

    private var isConfirming: Bool {
        if case .confirming = hub.pairingState { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch hub.pairingState {
        case .open(let code, let endsAt, let failures):
            Text("Open Levels on your iPhone, choose Connect to your Mac, and type this code.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Text(PairingCrypto.displayCode(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text("This Mac shows as Levels-\(hub.tag)").font(.callout)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(endsAt.timeIntervalSince(context.date).rounded(.up)))
                Text("Code works for \(left / 60):\(String(format: "%02d", left % 60))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if failures > 0 {
                Text(failures == 1 ? "1 wrong try" : "\(failures) wrong tries").font(.caption).foregroundStyle(.orange)
            }
        case .confirming(let name, let confirmationCode, _):
            Text("Does \(name) show this number?")
                .multilineTextAlignment(.center).font(.callout)
            Text(PairingCrypto.displayCode(confirmationCode))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .accessibilityLabel(confirmationCode.map(String.init).joined(separator: " "))
            Text("Tap They match only if both screens show the same number. If they differ, tap Cancel: someone else may be trying to connect.")
                .multilineTextAlignment(.center).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .matched(let name):
            ProgressView()
            Text("Finishing pairing with \(name)…").font(.callout)
        case .locked:
            Text("Too many tries. Get a new code.")
            Button("New Code") { hub.openPairing() }
        case .closed:
            Text("The code expired.")
            Button("New Code") { hub.openPairing() }
        case .paired(let name):
            Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .task {
                    try? await Task.sleep(for: .seconds(3))  // R7: closes after 3 s
                    dismiss()
                }
        }
    }
}
