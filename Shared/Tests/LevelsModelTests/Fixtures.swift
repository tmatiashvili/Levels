import Foundation
@testable import LevelsModel

/// Fixed clock for deterministic tests.
let now = Date(timeIntervalSince1970: 1_800_000_000)
let minute: TimeInterval = 60
let hour: TimeInterval = 3600

func battery(
    _ id: DeviceID = DeviceID(UUID()),
    kind: DeviceKind = .iphone,
    name: String = "Device",
    level: Int? = 60,
    isCharging: Bool = false,
    updatedAt: Date = now,
    serverModifiedAt: Date? = nil
) -> DeviceBattery {
    let accessory = kind == .accessory
        ? AccessoryInfo(parentDeviceID: DeviceID(UUID()), kind: .airpods, groupID: UUID(), component: .left)
        : nil
    return DeviceBattery(id: id, name: name, kind: kind, accessory: accessory, level: level, isCharging: isCharging,
                  updatedAt: updatedAt, serverModifiedAt: serverModifiedAt)
}
