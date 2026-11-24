// LIVE-001 R1, R4: the start/stop controls. A pin button in the Devices screen toolbar and a
// "Lock Screen" section in Settings, both on the same controller.
import LevelsModel
import SwiftUI

/// Devices screen toolbar: "Pin to Lock Screen" / "Unpin". Hidden while sample devices are on
/// or no Mac is paired (R3).
struct LiveActivityToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let live = model.liveActivity
        Group {
            if live.isRunning {
                Button { Task { await live.stop() } } label: {
                    Label("Unpin from Lock Screen", systemImage: "pin.slash")
                }
            } else if model.pairedMac != nil, !model.isDemo {
                Button { start() } label: {
                    Label("Pin levels to Lock Screen", systemImage: "pin")
                }
            }
        }
        .alert("Couldn't pin the levels", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func start() {
        Task {
            if let blocker = model.liveActivity.startBlocker(isDemo: model.isDemo) {
                error = LiveActivityText.blocker(blocker)
                return
            }
            do { try await model.liveActivity.start(isDemo: model.isDemo) } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Settings: a toggle and what to expect (R4, R40).
struct LiveActivitySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let live = model.liveActivity
        Section {
            Toggle("Show levels on Lock Screen", isOn: Binding(
                get: { live.isRunning },
                set: { on in
                    Task {
                        if !on { await live.stop(); return }
                        if let blocker = live.startBlocker(isDemo: model.isDemo) {
                            error = LiveActivityText.blocker(blocker)
                            return
                        }
                        do { try await live.start(isDemo: model.isDemo) } catch { self.error = error.localizedDescription }
                    }
                }))
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text(LiveActivityText.footer)
        }
    }
}

enum LiveActivityText {
    static func blocker(_ b: LiveLevelsPolicy.StartBlocker) -> String {
        switch b {
        case .notAllowed: String(localized: "This needs Levels Pro.")
        case .disabledInSettings: String(localized: "Live Activities are off for Levels. Turn them on in Settings > Levels.")
        case .notPaired: String(localized: "Connect your Mac first.")
        case .demo: String(localized: "Turn off sample devices first.")
        }
    }

    /// R40: honest about freshness.
    static var footer: String {
        #if LEVELS_PUSH
        String(localized: "Shows this iPhone, your Mac and AirPods on the Lock Screen and in the Dynamic Island for up to 8 hours. Your Mac sends new levels as they change.")
        #else
        String(localized: "Shows this iPhone, your Mac and AirPods on the Lock Screen and in the Dynamic Island for up to 8 hours. It updates live while Levels is open. While Levels is closed, iOS lets it update only now and then, so the levels can be old; the time shows when they were read.")
        #endif
    }
}
