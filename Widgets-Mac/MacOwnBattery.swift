// This Mac's battery, read by the widget itself at each timeline load (IOKit power sources,
// allowed in the sandboxed extension). The app writes the Mac's record at most once a minute and
// only while it runs, so without this the widget showed the level of the app's last write.
import Foundation
import IOKit.ps
import LevelsModel
import LevelsWidgetKit
import os

enum MacOwnBattery {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "widget")

    @Sendable static func read() async -> OwnBatteryReading? {
        let reading = OwnBatteryReading.macPowerSources(descriptions(),
                                                        isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                        readAt: Date())
        logger.notice("Widget: own battery \(reading?.level.map(String.init) ?? "unknown", privacy: .public)")
        return reading
    }

    /// One description per power source, or `nil` when IOPS answered nothing.
    private static func descriptions() -> [[String: Any]]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        return list.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }
    }
}
