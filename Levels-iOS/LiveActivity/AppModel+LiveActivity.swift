// LIVE-001 R21: the background paths that may update the Live Activity while the iPhone is
// locked, on the free build. Kept out of AppModel.swift.
import Foundation
import LevelsModel

extension AppModel {
    /// A Shortcuts "Report Battery" run (RPT-002) just reported. While a Live Activity runs, also
    /// ask the Mac for its levels (at most 5 s) and update the activity, so the Mac and AirPods
    /// move along with this iPhone's own level. Without a Live Activity: nothing, as before.
    func refreshLiveActivityAfterIntent() async {
        guard liveActivity.isRunning else { return }
        if !isDemo {
            let hub = hub
            _ = await Self.within(.seconds(5)) { await hub.refresh(.backgroundRefresh) }
        }
        await liveActivity.refresh()
    }
}
