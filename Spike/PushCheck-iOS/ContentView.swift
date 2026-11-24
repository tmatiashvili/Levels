// SPIKE-001 throwaway code. Not kept after the spike.

import SwiftUI
import UIKit

struct ContentView: View {
    let log: PushLog
    @State private var confirmClear = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Container", value: SpikeConfig.containerID)
                    LabeledContent("Subscription", value: SpikeConfig.subscriptionID)
                    LabeledContent("Pushes logged", value: "\(log.pushCount)")
                }
                Section("Log, newest first") {
                    if log.lines.isEmpty {
                        Text("No entries yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(log.lines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.contains("| PUSH |") ? .green : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Push Check")
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: log.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = log.text
                        copied = true
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        Task { await CloudSetup.run(log: log) }
                    } label: {
                        Label("Run setup", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
            .alert("Log copied", isPresented: $copied) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Clear the whole log?", isPresented: $confirmClear) {
                Button("Clear log", role: .destructive) { log.clear() }
            }
        }
    }
}
