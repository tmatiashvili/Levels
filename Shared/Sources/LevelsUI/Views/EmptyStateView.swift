import SwiftUI

/// Loading, empty and only-this-device states (R11).
public struct EmptyStateView: View {
    let state: DeviceListStore.State

    public init(state: DeviceListStore.State) { self.state = state }

    public var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .empty:
            Text("No devices yet. Install Levels on your other devices, signed in to the same Apple ID.", bundle: .module)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        case .onlyThisDevice:
            Text("Other devices appear here when they run Levels.", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
