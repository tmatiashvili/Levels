import SwiftUI

extension EnvironmentValues {
    /// True in the local-only Mac build (owner decision K): no other devices can appear, so the
    /// empty states don't mention Apple ID or installing Levels elsewhere.
    @Entry public var isLocalOnly: Bool = false
}

/// Loading, empty and only-this-device states (R11).
public struct EmptyStateView: View {
    let state: DeviceListStore.State
    @Environment(\.isLocalOnly) private var isLocalOnly

    public init(state: DeviceListStore.State) { self.state = state }

    public var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .empty:
            Group {
                if isLocalOnly {
                    Text("No battery readings yet. Only this Mac and its accessories show up for now.", bundle: .module)
                } else {
                    Text("No devices yet. Install Levels on your other devices, signed in to the same Apple ID.", bundle: .module)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
        case .onlyThisDevice:
            Group {
                if isLocalOnly {
                    Text("Only this Mac and its accessories show up for now.", bundle: .module)
                } else {
                    Text("Other devices appear here when they run Levels.", bundle: .module)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
