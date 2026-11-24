import Foundation
import LevelsModel

/// Parses `/usr/bin/pmset -g accps -xml` (ADR-0015 amendment, 2026-11-24): macOS's own
/// accessory power sources, the data behind the Batteries widget. Pure: the Mac app runs
/// the process and passes its stdout here.
///
/// Why this source: `bluetoothd` publishes one power source per AirPods part (Left, Right,
/// Case, inside a `Combined` source for the buds) with a 1 % level and **Is Charging**. It
/// keeps them current from the AirPods' Bluetooth LE advertisements, which it can decrypt
/// because it holds the pairing keys, so the sources exist for the owner's paired AirPods
/// only, and also while they sit in the case **not connected** to this Mac (verified on the
/// owner's Mac, 2026-11-24). Other people's AirPods never get a power source.
///
/// Rules:
/// - Only `Type = "Accessory Source"` with `Is Present = true` and a Bluetooth transport.
///   A source that is not present gives no reading (nothing was heard).
/// - The source is tied to a paired device from `system_profiler` (its Bluetooth address
///   keeps the record IDs the connected readings use): same vendor ID and product ID, and a
///   headphone. If several paired headphones share them, the name must pick exactly one;
///   otherwise the accessory is skipped and a problem is added (never guess).
/// - Level: `Current Capacity` of `Max Capacity` (normally 100), 0...100.
/// - Charging: ``ChargingFlags`` with `charging = Is Charging`, `onExternalPower =
///   Power Source State == "AC Power"` (a bud in the case, or a case on a charger), and
///   `full = Is Charged`. Never inferred from level changes.
/// - `readAt = now`: macOS removes the source when the AirPods are no longer heard, so a
///   present source is current at the time of the read. (**Assumption:** not yet watched
///   with the AirPods out of range.)
public enum PowerSourceAccessoryParser {
    static let typeKey = "Type"
    static let accessoryType = "Accessory Source"
    static let presentKey = "Is Present"
    static let transportKey = "Transport Type"
    static let partKey = "Part Identifier"
    static let partsKey = "Combined Parts"
    static let groupKey = "Group Identifier"
    static let accessoryIDKey = "Accessory Identifier"
    static let nameKey = "Name"
    static let vendorKey = "Vendor ID"
    static let productKey = "Product ID"
    static let currentKey = "Current Capacity"
    static let maxKey = "Max Capacity"
    static let chargingKey = "Is Charging"
    static let chargedKey = "Is Charged"
    static let stateKey = "Power Source State"
    static let acPower = "AC Power"
    static let batteryPower = "Battery Power"

    static let components: [String: AccessoryComponent] = [
        "Left": .left, "Right": .right, "Case": .case, "Single": .main, "Main": .main,
    ]

    /// One part of one accessory as macOS reports it.
    struct Part: Equatable {
        var group: String
        var name: String
        var vendorID: Int
        var productID: Int
        var component: AccessoryComponent
        var level: Int
        var flags: ChargingFlags
    }

    public static func parse(_ data: Data, paired: [PairedBluetoothDevice], now: Date) -> AccessoryScan {
        var scan = AccessoryScan()
        let (parts, problems) = self.parts(data)
        scan.problems = problems
        let groups = Dictionary(grouping: parts, by: \.group)
        for group in groups.keys.sorted() {
            let members = groups[group]!
            guard let device = match(members, paired: paired, problems: &scan.problems) else { continue }
            for part in members {
                scan.readings.append(AccessoryReading(
                    key: device.key, name: device.name, kind: device.kind, component: part.component,
                    level: part.level, readAt: now,
                    isCharging: part.flags.isCharging, isPluggedIn: part.flags.isPluggedIn))
            }
        }
        scan.readings.sort { ($0.name, $0.id.recordName) < ($1.name, $1.id.recordName) }
        return AccessoryScan.merged([scan])  // one reading per record ID
    }

    /// What a change notification compares: the present Bluetooth accessory parts with their
    /// level and charging flags, sorted. Source IDs are left out (macOS renumbers them).
    public static func fingerprint(_ data: Data) -> [String] {
        parts(data).parts.map {
            "\($0.group)|\($0.component.rawValue)|\($0.level)|\($0.flags.isCharging)|\(String(describing: $0.flags.isPluggedIn))"
        }.sorted()
    }

    // MARK: Parsing

    static func parts(_ data: Data) -> (parts: [Part], problems: Set<String>) {
        var parts: [Part] = []
        var problems = Set<String>()
        for source in plists(data) {
            guard (source[typeKey] as? String) == accessoryType, flag(source[presentKey]) == true,
                  (source[transportKey] as? String)?.localizedCaseInsensitiveContains("bluetooth") == true
            else { continue }
            let members: [[String: Any]]
            if let combined = source[partsKey] {
                guard let list = combined as? [[String: Any]], !list.isEmpty else {
                    problems.insert("pmset: Combined Parts is not a list of parts")
                    continue
                }
                members = list.filter { flag($0[presentKey]) != false }
            } else {
                members = [source]
            }
            let group = (source[groupKey] as? String) ?? (source[accessoryIDKey] as? String) ?? ""
            // One part that can't be trusted drops the whole source (never guess).
            var accepted: [Part] = []
            var trusted = true
            for member in members {
                switch part(member, group: group) {
                case .success(let p): accepted.append(p)
                case .failure(let problem):
                    problems.insert(problem.message)
                    trusted = false
                }
                if !trusted { break }
            }
            if trusted { parts.append(contentsOf: accepted) }
        }
        return (parts, problems)
    }

    struct Problem: Error { let message: String }

    static func part(_ props: [String: Any], group: String) -> Result<Part, Problem> {
        guard !group.isEmpty else { return .failure(Problem(message: "pmset: an accessory source has no group identifier")) }
        let partID = (props[partKey] as? String) ?? "Single"
        guard let component = components[partID] else {
            return .failure(Problem(message: "pmset: unknown Part Identifier \(partID)"))
        }
        guard let vendor = integer(props[vendorKey]), let product = integer(props[productKey]) else {
            return .failure(Problem(message: "pmset: an accessory source has no vendor or product ID"))
        }
        guard let current = integer(props[currentKey]) else {
            return .failure(Problem(message: "pmset: Current Capacity is not an integer"))
        }
        let maximum = props[maxKey] == nil ? 100 : integer(props[maxKey])
        guard let maximum, maximum > 0, (0...maximum).contains(current) else {
            return .failure(Problem(message: "pmset: Current Capacity is outside 0...Max Capacity"))
        }
        guard let charging = flag(props[chargingKey]) else {
            return .failure(Problem(message: "pmset: Is Charging is not a boolean"))
        }
        let level = maximum == 100 ? current : Int((Double(current) * 100 / Double(maximum)).rounded())
        let onPower: Bool? = switch props[stateKey] as? String {
        case acPower: true
        case batteryPower: false
        default: nil
        }
        let flags = ChargingFlags(charging: charging, onExternalPower: onPower, full: flag(props[chargedKey]) == true)
        let name = ((props[nameKey] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Part(group: group, name: name, vendorID: vendor, productID: product,
                             component: component, level: level, flags: flags))
    }

    /// The paired headphone a group of parts belongs to, or `nil` (with a problem when it is ambiguous).
    static func match(_ parts: [Part], paired: [PairedBluetoothDevice], problems: inout Set<String>) -> PairedBluetoothDevice? {
        guard let first = parts.first else { return nil }
        let candidates = paired.filter {
            $0.isHeadphones && $0.vendorID == first.vendorID && $0.productID == first.productID
        }
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty {
            problems.insert("pmset: an accessory power source matches no paired headphones")
            return nil
        }
        // The buds' sources carry the device name; the case's is "<name> Case".
        let names = Set(parts.filter { $0.component != .case }.map(\.name).filter { !$0.isEmpty })
        let byName = candidates.filter { names.contains($0.name) }
        if byName.count == 1 { return byName[0] }
        problems.insert("pmset: an accessory power source matches several paired headphones")
        return nil
    }

    /// `pmset -g accps -xml` prints one XML plist per power source, back to back.
    static func plists(_ data: Data) -> [[String: Any]] {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "<?xml").dropFirst().compactMap { chunk in
            guard let body = ("<?xml" + chunk).data(using: .utf8) else { return nil }
            return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        }
    }

    /// `pmset` writes some flags as `<true/>` and some as `<integer>0</integer>`.
    static func flag(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        switch n.intValue {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              Double(n.intValue) == n.doubleValue else { return nil }
        return n.intValue
    }
}
