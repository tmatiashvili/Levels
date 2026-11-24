import SwiftUI

/// DEMO-001 R3: the bar shown on every iPhone screen while demo mode is on.
public struct SampleDevicesBanner: View {
    let onExit: () -> Void

    public init(onExit: @escaping () -> Void) { self.onExit = onExit }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sample devices", bundle: .module).font(.subheadline.weight(.semibold))
                Text("These aren't your devices.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onExit) { Text("Exit", bundle: .module) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Sample devices banner") {
    SampleDevicesBanner(onExit: {}).padding()
}
