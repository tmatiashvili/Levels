// RPT-001 / ADR-0010 iPhone reader. Lives in the app target, not Shared: ADR-0010 keeps
// platform readers in the app targets. The pure mapping it uses (`BatteryReading.level(fromFraction:)`)
// is in LevelsReaders.
import Foundation
import LevelsReaders
import UIKit

/// Reads this iPhone's battery through `UIDevice` (RPT-001 R1–R3, R5). Never throws; the
/// Simulator answers level −1 and `.unknown`, which the reporter drops (R3).
struct UIDeviceBatteryReader: BatteryReader {
    /// R1: once at launch, before any read; never turned off.
    @MainActor static func enableMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func read() async -> BatteryReading { await Self.readNow() }

    /// R5: the level, state and Low Power Mode notifications, merged. Each element is a fresh
    /// read; bursts collapse to the newest one. They arrive only while the process runs.
    func changes() -> AsyncStream<BatteryReading> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let names: [Notification.Name] = [
                UIDevice.batteryLevelDidChangeNotification,
                UIDevice.batteryStateDidChangeNotification,
                .NSProcessInfoPowerStateDidChange,
            ]
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for name in names {
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                                continuation.yield(await Self.readNow())
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `UIDevice` is main-actor isolated in Swift 6 (ADR-0010).
    @MainActor static func readNow() -> BatteryReading {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        return Self.reading(rawLevel: Double(device.batteryLevel), state: device.batteryState,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, now: Date())
    }

    /// R2: the raw level through ADR-0010 rule 1, the state one to one (iOS never gives `.pluggedIn`).
    nonisolated static func reading(rawLevel: Double, state: UIDevice.BatteryState, lowPowerMode: Bool,
                                    now: Date) -> BatteryReading {
        let powerState: BatteryReading.PowerState = switch state {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        case .unknown: .unknown
        @unknown default: .unknown
        }
        return BatteryReading(level: BatteryReading.level(fromFraction: rawLevel), powerState: powerState,
                              isLowPowerMode: lowPowerMode, readAt: now)
    }
}
