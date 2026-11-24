// RPT-002 "Setup guide": the 7 Shortcuts automations that run "Report Battery".
import AppIntents
import SwiftUI

struct ShortcutsGuideView: View {
    /// True when shown as its own sheet (the hint card's "Show me how").
    let showsDone: Bool
    @Environment(\.dismiss) private var dismiss

    private static let steps: [LocalizedStringKey] = [
        "Open the **Shortcuts** app and tap **Automation**.",
        "Tap **+**, then choose **Charger**. Tick **Is Connected** and **Is Disconnected**. Choose **Run Immediately**. Tap **Next**.",
        "Search for **Report Battery** (Levels) and pick it. Tap **Done**.",
        "Tap **+** again and choose **Battery Level**. Pick **Falls Below** and set **80%**. Choose **Run Immediately**, tap **Next**, pick **Report Battery**, tap **Done**.",
        "Repeat step 4 for **Falls Below 60%**, **40%** and **20%**.",
        "Repeat step 4 with **Rises Above 50%** and **Rises Above 90%**.",
        "If Shortcuts asks about notifications, turn **Notify When Run** off.",
    ]

    var body: some View {
        List {
            Section {
                Text("You'll make 7 automations. They all run \"Report Battery\".")
            }
            Section("Steps") {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                ShortcutsLink()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Want finer updates? Add more steps, for example every 10%. Each automation runs only when the battery crosses its level, so more of them cost almost nothing.")
            }
        }
        .navigationTitle("Background updates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview("Guide") {
    NavigationStack { ShortcutsGuideView(showsDone: true) }
}
