// SPIKE-001 throwaway code. Not kept after the spike.

import AppKit
import SwiftUI

struct WriterView: View {
    let writer: RecordWriter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Container: \(SpikeConfig.containerID)")
                .font(.callout.monospaced())
            Text("Signed container environment: \(RecordWriter.signedContainerEnvironment)")
                .font(.callout.monospaced())
                .foregroundStyle(RecordWriter.signedContainerEnvironment == "Production" ? .green : .red)
            Text("Writes so far: \(writer.writeCount)")

            HStack {
                Button("Write DeviceBattery record") {
                    Task { await writer.write() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                if writer.isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(writer.text, forType: .string)
                }
                Button("Delete test record", role: .destructive) {
                    Task { await writer.deleteTestRecord() }
                }
            }
            .disabled(writer.isBusy)

            List(Array(writer.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(line.contains("| ERROR |") ? .red : .primary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 360)
    }
}
