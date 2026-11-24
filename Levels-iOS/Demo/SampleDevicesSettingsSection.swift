// DEMO-001 R3: Settings ▸ Sample devices, shown only while demo mode is on.
import SwiftUI

struct SampleDevicesSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if model.isDemo {
            Section {
                Button("Exit sample devices") {
                    dismiss()
                    Task { await model.exitDemo() }
                }
            } header: {
                Text("Sample devices")
            } footer: {
                Text("Levels is showing sample devices. Your own levels, Mac pairing and settings are kept and come back when you exit.")
            }
        }
    }
}
