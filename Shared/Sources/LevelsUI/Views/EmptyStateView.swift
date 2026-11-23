import SwiftUI

extension EnvironmentValues {
    /// True in the local-only builds (owner decisions K and M, before the hub client): no other
    /// devices can appear, so the empty states don't mention Apple ID or installing Levels elsewhere.
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
                    #if os(iOS)
                    Text("No battery reading yet. Pull down to read this iPhone's battery.", bundle: .module)
                    #else
                    Text("No battery readings yet. Only this Mac and its accessories show up for now.", bundle: .module)
                    #endif
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
                    #if os(iOS)
                    Text("Only this iPhone shows up for now. Your Mac and its accessories appear once Levels can connect to your Mac.", bundle: .module)
                    #else
                    Text("Only this Mac and its accessories show up for now.", bundle: .module)
                    #endif
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
