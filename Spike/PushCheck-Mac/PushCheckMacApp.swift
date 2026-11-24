// SPIKE-001 throwaway code. Not kept after the spike.

import SwiftUI

@main
struct PushCheckMacApp: App {
    @State private var writer = RecordWriter()

    var body: some Scene {
        WindowGroup("Push Check (Mac writer)") {
            WriterView(writer: writer)
        }
    }
}
