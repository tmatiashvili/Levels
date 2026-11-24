import Foundation
import LevelsModel

/// Parses `/usr/sbin/system_profiler SPBluetoothDataType -json` (MAC-003 R2, ADR-0015).
/// Pure: the Mac app runs the process and passes its stdout here.
///
/// Only `device_connected` is read. `device_not_connected` keeps cached last-known levels
/// (verified on the owner's Mac, 2026-11-23) and is ignored. Per connected device, the
/// `device_batteryLevel{Left,Right,Case,Main}` strings (`"NN%"`) become one reading each.
/// A device with no battery key is not a battery device and is skipped silently. A device
/// whose battery keys can't be trusted (unknown key, bad value, missing address) is not
/// reported at all and adds a problem (R5: never guess).
public enum SystemProfilerBluetoothParser {
    static let rootKey = "SPBluetoothDataType"
    static let connectedKey = "device_connected"
    static let notConnectedKey = "device_not_connected"
    static let productKey = "device_productID"
    static let controllerKey = "controller_properties"
    static let addressKey = "device_address"
    static let minorTypeKey = "device_minorType"
    static let vendorKey = "device_vendorID"
    static let batteryPrefix = "device_batteryLevel"
    /// Apple's Bluetooth vendor ID (AirPods and Beats).
    static let appleVendor = "0x004C"

    static let components: [String: AccessoryComponent] = [
        "Left": .left, "Right": .right, "Case": .case, "Main": .main,
    ]

    public static func parse(_ data: Data, now: Date) -> AccessoryScan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root[rootKey] as? [[String: Any]]
        else { return AccessoryScan(problems: ["system_profiler: output is not the SPBluetoothDataType JSON"]) }

        var scan = AccessoryScan()
        // The sandbox blanks the report to `[{}]` (ADR-0013 probe); so does a missing controller.
        if !sections.contains(where: { $0[controllerKey] != nil }) {
            scan.problems.insert("system_profiler: no Bluetooth controller in the output")
        }
        for section in sections {
            guard let list = section[connectedKey] else { continue }
            guard let entries = list as? [[String: Any]] else {
                scan.problems.insert("system_profiler: device_connected is not a list of devices")
                continue
            }
            for entry in entries {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else {
                        scan.problems.insert("system_profiler: a connected device has no properties")
                        continue
                    }
                    parseDevice(name: name, props: props, now: now, into: &scan)
                }
            }
        }
        scan.readings.sort { ($0.name, $0.id.recordName) < ($1.name, $1.id.recordName) }
        return AccessoryScan.merged([scan])  // one reading per record ID
    }

    private static func parseDevice(name: String, props: [String: Any], now: Date, into scan: inout AccessoryScan) {
        let minorType = (props[minorTypeKey] as? String) ?? ""
        let isHeadphones = minorType.localizedCaseInsensitiveContains("headphone")
            || minorType.localizedCaseInsensitiveContains("headset")
        if isHeadphones { scan.headphonesConnected = true }

        let batteryKeys = props.keys.filter { $0.hasPrefix(batteryPrefix) }
        guard !batteryKeys.isEmpty else { return }

        guard let rawAddress = props[addressKey] as? String, let key = BluetoothAddress.normalized(rawAddress) else {
            scan.problems.insert("system_profiler: a connected device with a battery has no valid device_address")
            return
        }
        var readings: [AccessoryReading] = []
        let kind = accessoryKind(minorType: minorType, vendor: props[vendorKey] as? String, isHeadphones: isHeadphones)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for batteryKey in batteryKeys.sorted() {
            let suffix = String(batteryKey.dropFirst(batteryPrefix.count))
            guard let component = components[suffix] else {
                scan.problems.insert("system_profiler: unknown battery key \(batteryKey)")
                return
            }
            guard let level = percent(props[batteryKey]) else {
                scan.problems.insert("system_profiler: \(batteryKey) is not an NN% value")
                return
            }
            readings.append(AccessoryReading(key: key, name: trimmedName.isEmpty ? defaultName(kind) : trimmedName,
                                             kind: kind, component: component, level: level, readAt: now))
        }
        scan.readings.append(contentsOf: readings)
    }

    /// Every device paired with this Mac, connected or not, with what identifies it. The
    /// power-source parser uses it to tie an AirPods power source to its Bluetooth address
    /// (ADR-0015 amendment). No levels: `device_not_connected` levels have no reading time.
    /// Devices without a valid address are left out.
    public static func pairedDevices(_ data: Data) -> [PairedBluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root[rootKey] as? [[String: Any]] else { return [] }
        var out: [PairedBluetoothDevice] = []
        for section in sections {
            for (listKey, connected) in [(connectedKey, true), (notConnectedKey, false)] {
                guard let entries = section[listKey] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (name, value) in entry {
                        guard let props = value as? [String: Any],
                              let raw = props[addressKey] as? String, let key = BluetoothAddress.normalized(raw)
                        else { continue }
                        let minorType = (props[minorTypeKey] as? String) ?? ""
                        let isHeadphones = minorType.localizedCaseInsensitiveContains("headphone")
                            || minorType.localizedCaseInsensitiveContains("headset")
                        let vendor = props[vendorKey] as? String
                        let kind = accessoryKind(minorType: minorType, vendor: vendor, isHeadphones: isHeadphones)
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        out.append(PairedBluetoothDevice(
                            key: key, name: trimmed.isEmpty ? defaultName(kind) : trimmed, kind: kind,
                            vendorID: hexID(vendor), productID: hexID(props[productKey] as? String),
                            isHeadphones: isHeadphones, isConnected: connected))
                    }
                }
            }
        }
        return out.sorted { $0.key < $1.key }
    }

    /// `"0x2024"` → 0x2024; anything else is `nil`.
    static func hexID(_ value: String?) -> Int? {
        guard let s = value?.trimmingCharacters(in: .whitespaces).lowercased(), s.hasPrefix("0x") else { return nil }
        let digits = s.dropFirst(2)
        guard (1...4).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return Int(digits, radix: 16)
    }

    /// `"45%"` → 45. Only 0...100 followed by `%`; anything else is `nil` (R5).
    static func percent(_ value: Any?) -> Int? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), s.hasSuffix("%") else { return nil }
        let digits = s.dropLast()
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }

    static func accessoryKind(minorType: String, vendor: String?, isHeadphones: Bool) -> AccessoryKind {
        let t = minorType.lowercased()
        if isHeadphones { return vendor?.uppercased().hasPrefix("0X004C") == true ? .airpods : .other }
        if t.contains("mouse") { return .mouse }
        if t.contains("keyboard") { return .keyboard }
        if t.contains("trackpad") { return .trackpad }
        return .other
    }

    static func defaultName(_ kind: AccessoryKind) -> String {
        switch kind {
        case .airpods: "AirPods"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        case .trackpad: "Trackpad"
        case .other: "Accessory"
        }
    }
}

/// Maps `AppleDeviceManagementHIDEventService` registry properties (MAC-003 R1, ADR-0015)
/// to readings. Pure: the Mac app reads the properties through IOKit and passes them here,
/// one dictionary per service, with the registry's key names.
///
/// A service without `BatteryPercent` (the built-in keyboard and trackpad, USB devices)
/// is not a battery accessory and is skipped silently. One with `BatteryPercent` but no
/// usable `DeviceAddress` or level is not reported and adds a problem (R5).
public enum HIDAccessoryParser {
    public static let batteryKey = "BatteryPercent"
    public static let productKey = "Product"
    public static let addressKey = "DeviceAddress"
    public static let builtInKey = "Built-In"
    /// The keys the app reads from each service.
    public static let keys = [batteryKey, productKey, addressKey, builtInKey]

    public static func parse(_ services: [[String: Any]], now: Date) -> AccessoryScan {
        var scan = AccessoryScan()
        for props in services {
            guard let rawLevel = props[batteryKey] else { continue }
            if props[builtInKey] as? Bool == true { continue }
            guard let number = rawLevel as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Double(number.intValue) == number.doubleValue, (0...100).contains(number.intValue) else {
                scan.problems.insert("IOKit: BatteryPercent is not an integer 0–100")
                continue
            }
            let key: String? = switch props[addressKey] {
            case let s as String: BluetoothAddress.normalized(s)
            case let d as Data: BluetoothAddress.normalized(d)
            default: nil
            }
            guard let key else {
                scan.problems.insert("IOKit: a HID device with BatteryPercent has no valid DeviceAddress")
                continue
            }
            let product = (props[productKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = kind(product: product)
            scan.readings.append(AccessoryReading(
                key: key, name: product.isEmpty ? SystemProfilerBluetoothParser.defaultName(kind) : product,
                kind: kind, component: .main, level: number.intValue, readAt: now))
        }
        // A keyboard can expose several services for one address: one record each.
        return AccessoryScan.merged([scan])
    }

    static func kind(product: String) -> AccessoryKind {
        let p = product.lowercased()
        if p.contains("mouse") { return .mouse }
        if p.contains("keyboard") { return .keyboard }
        if p.contains("trackpad") { return .trackpad }
        return .other
    }
}

/// A device paired with this Mac, as `system_profiler SPBluetoothDataType` lists it.
public struct PairedBluetoothDevice: Sendable, Equatable {
    /// The normalised Bluetooth address (``AccessoryReading/key``).
    public var key: String
    public var name: String
    public var kind: AccessoryKind
    /// `device_vendorID` (Apple: 0x004C).
    public var vendorID: Int?
    /// `device_productID` (AirPods Pro 2 with USB-C: 0x2024).
    public var productID: Int?
    public var isHeadphones: Bool
    public var isConnected: Bool

    public init(key: String, name: String, kind: AccessoryKind, vendorID: Int?, productID: Int?,
                isHeadphones: Bool, isConnected: Bool) {
        self.key = key
        self.name = name
        self.kind = kind
        self.vendorID = vendorID
        self.productID = productID
        self.isHeadphones = isHeadphones
        self.isConnected = isConnected
    }
}
