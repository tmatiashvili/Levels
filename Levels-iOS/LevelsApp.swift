// Levels-iOS entry point (UI-002, RPT-001, RPT-002). Logic lives in Shared/ (ADR-0003); this
// target wires it (AppModel) and holds the iPhone screens, the UIDevice reader and the intent.
import AppIntents
import LevelsUI
import SwiftUI

@main
struct LevelsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    init() {
        // RPT-002 Design: before any intent can run.
        let reporter = AppModel.shared.reporter
        AppDependencyManager.shared.add(dependency: reporter)
        AppModel.logger.notice("Launched")
    }

    var body: some Scene {
        WindowGroup {
            DevicesScreen()
                .environment(model)
                .environment(model.store)
                .environment(\.isLocalOnly, true)  // hub mode: empty states talk about this iPhone and the Mac
                .task { await model.start() }
                .onOpenURL { model.handle($0) }  // UI-002 R9
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()  // RPT-001 R4, UI-002 R3, NET-004 R6
            case .background: model.enteredBackground()  // RPT-001 R6
            default: model.resignedActive()  // NET-003 R7: no long-poll unless active
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {  // RPT-001 R7
            await model.backgroundRefresh()
        }
    }
}
