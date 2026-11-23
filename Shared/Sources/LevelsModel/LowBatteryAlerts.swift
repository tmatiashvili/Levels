import Foundation
import Synchronization

// ALR-001: low-battery alerts, Mac-first local build. Pure rules; the app posts the alerts.

/// Alert settings of this device (ALR-001 R1, R4, R7). Local, never synced.
public struct AlertSettings: Codable, Sendable, Equatable {
    public static let thresholdRange = 5...50
    public static let thresholdStep = 5
    public static let defaultThreshold = 20
    /// A disarmed subject re-arms at `threshold + rearmMargin` (R5).
    public static let rearmMargin = 10
    /// Readings older than this never alert (R6).
    public static let maxReadingAge: TimeInterval = 3600

    /// Master switch (R1).
    public var isEnabled: Bool
    /// 5...50 in steps of 5 (R4). Always stored normalised.
    public var threshold: Int { didSet { threshold = Self.normalised(threshold) } }
    /// Row IDs switched off (R7): a record ID, or the group ID of a grouped accessory.
    public var mutedDevices: Set<DeviceID>

    public init(isEnabled: Bool, threshold: Int = AlertSettings.defaultThreshold, mutedDevices: Set<DeviceID> = []) {
        self.isEnabled = isEnabled
        self.threshold = Self.normalised(threshold)
        self.mutedDevices = mutedDevices
    }

    /// Owner decision H: on for Mac and iPad, off for iPhone and Watch (and anything else).
    public static func defaultEnabled(for kind: DeviceKind) -> Bool {
        switch kind {
        case .mac, .ipad: true
        case .iphone, .watch, .accessory, .other: false
        }
    }

    /// The settings a device of `kind` starts with.
    public static func defaults(for kind: DeviceKind) -> AlertSettings {
        AlertSettings(isEnabled: defaultEnabled(for: kind))
    }

    /// Clamps to ``thresholdRange`` and rounds to the nearest ``thresholdStep``.
    public static func normalised(_ threshold: Int) -> Int {
        let clamped = min(thresholdRange.upperBound, max(thresholdRange.lowerBound, threshold))
        let stepped = Int((Double(clamped) / Double(thresholdStep)).rounded()) * thresholdStep
        return min(thresholdRange.upperBound, max(thresholdRange.lowerBound, stepped))
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, threshold, mutedDevices }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
                  threshold: try c.decodeIfPresent(Int.self, forKey: .threshold) ?? Self.defaultThreshold,
                  mutedDevices: try c.decodeIfPresent(Set<DeviceID>.self, forKey: .mutedDevices) ?? [])
    }
}

/// Which subjects already alerted in their current discharge cycle (R5).
public struct AlertState: Codable, Sendable, Equatable {
    /// Subject keys that are disarmed; every other subject is armed.
    public var disarmed: Set<String>

    public init(disarmed: Set<String> = []) { self.disarmed = disarmed }
}

/// One thing that can alert (R3): a whole device, or an AirPods group's earbuds or case.
public struct AlertSubject: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable { case whole, earbuds, `case` }

    /// `<recordName>`, `<groupID>:earbuds` or `<groupID>:case`.
    public var key: String
    /// The list row this belongs to (R7, R9): record ID, or the group ID.
    public var rowID: DeviceID
    public var name: String
    public var part: Part
    public var level: Int?
    public var isCharging: Bool
    public var readingDate: Date

    public init(key: String, rowID: DeviceID, name: String, part: Part, level: Int?, isCharging: Bool, readingDate: Date) {
        self.key = key
        self.rowID = rowID
        self.name = name
        self.part = part
        self.level = level
        self.isCharging = isCharging
        self.readingDate = readingDate
    }
}

/// A notification to post (R8, R9).
public struct LowBatteryAlert: Sendable, Equatable {
    public var subjectKey: String
    public var rowID: DeviceID
    public var name: String
    public var part: AlertSubject.Part
    public var level: Int

    /// "Magic Mouse is at 15%", "TPods case is at 10%" (R8).
    public var text: String {
        part == .case ? "\(name) case is at \(level)%" : "\(name) is at \(level)%"
    }

    /// One notification per subject; a new one replaces the old (R8).
    public var identifier: String { "low-\(subjectKey)" }

    /// `levels://device/<row uuid>` (R9).
    public var url: URL { LevelsAppConfig.deviceURL(rowID) }
}

/// The ALR-001 decision rule.
public enum LowBatteryAlertRule {
    /// R2, R3: the subjects in a snapshot. Leaves out this device and hidden devices.
    public static func subjects(in snapshot: SnapshotFile, hidden: Set<DeviceID> = [], now: Date) -> [AlertSubject] {
        let preferences = DisplayPreferences(hidden: hidden)
        var result: [AlertSubject] = []
        var groups: [UUID: [DeviceBattery]] = [:]
        for d in snapshot.devices where d.id != snapshot.ownDeviceID && !DeviceOrdering.isHidden(d, in: preferences) {
            if let info = d.accessory, info.component != .main {
                groups[info.groupID, default: []].append(d)
            } else {
                result.append(AlertSubject(key: d.id.recordName, rowID: d.id, name: d.name, part: .whole,
                                           level: d.level, isCharging: d.isCharging, readingDate: d.readingDate(now: now)))
            }
        }
        for (groupID, members) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let rowID = DeviceID(groupID)
            let name = groupName(members)
            let buds = members.filter { $0.accessory?.component == .left || $0.accessory?.component == .right }
            if let lowest = lowest(buds) {
                result.append(AlertSubject(key: "\(rowID.recordName):earbuds", rowID: rowID, name: name, part: .earbuds,
                                           level: lowest.level, isCharging: lowest.isCharging,
                                           readingDate: lowest.readingDate(now: now)))
            }
            if let c = members.first(where: { $0.accessory?.component == .case }) {
                result.append(AlertSubject(key: "\(rowID.recordName):case", rowID: rowID, name: name, part: .case,
                                           level: c.level, isCharging: c.isCharging, readingDate: c.readingDate(now: now)))
            }
        }
        return result
    }

    /// R4–R7, R11: which alerts to post and the new state.
    ///
    /// Re-arming (charging, or level ≥ threshold + margin) happens even when alerts or the
    /// device are off; only posting needs both on. Late readings (R6) change nothing.
    /// Subjects no longer present are pruned from the state.
    public static func evaluate(_ subjects: [AlertSubject], settings: AlertSettings, state: AlertState,
                                reportingEnabled: Bool, now: Date) -> (alerts: [LowBatteryAlert], state: AlertState) {
        guard reportingEnabled else { return ([], AlertState()) }  // R11
        var disarmed = state.disarmed.intersection(subjects.map(\.key))
        var alerts: [LowBatteryAlert] = []
        for s in subjects {
            guard let level = s.level else { continue }
            guard now.timeIntervalSince(s.readingDate) <= AlertSettings.maxReadingAge else { continue }  // R6
            if disarmed.contains(s.key) {
                if s.isCharging || level >= settings.threshold + AlertSettings.rearmMargin { disarmed.remove(s.key) }
                continue
            }
            guard !s.isCharging, level <= settings.threshold else { continue }  // R4
            guard settings.isEnabled, !settings.mutedDevices.contains(s.rowID) else { continue }  // R1, R7
            disarmed.insert(s.key)
            alerts.append(LowBatteryAlert(subjectKey: s.key, rowID: s.rowID, name: s.name, part: s.part, level: level))
        }
        return (alerts, AlertState(disarmed: disarmed))
    }

    /// The component with the lowest level (one without a level only if none has one).
    static func lowest(_ components: [DeviceBattery]) -> DeviceBattery? {
        components.min { a, b in
            switch (a.level, b.level) {
            case let (x?, y?): x < y
            case (.some, nil): true
            default: false
            }
        }
    }

    /// The headset name: the shortest component name (same rule as UI-001 R13).
    static func groupName(_ components: [DeviceBattery]) -> String {
        let names = components.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.min { $0.count < $1.count } ?? components.first?.name ?? ""
    }
}

/// Where ``AlertSettings`` and ``AlertState`` are kept.
public protocol AlertStore: Sendable {
    /// Saved settings, or `defaults` when none were saved.
    func loadSettings(defaults: AlertSettings) -> AlertSettings
    func saveSettings(_ settings: AlertSettings)
    func loadState() -> AlertState
    func saveState(_ state: AlertState)
}

/// JSON in (App Group) `UserDefaults` under `alertSettings` and `alertState`.
public struct UserDefaultsAlertStore: AlertStore {
    public static let settingsKey = "alertSettings"
    public static let stateKey = "alertState"
    /// The App Group ID, or `nil` for `UserDefaults.standard`.
    public let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func loadSettings(defaults fallback: AlertSettings) -> AlertSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let s = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return fallback }
        return s
    }

    public func saveSettings(_ settings: AlertSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    public func loadState() -> AlertState {
        guard let data = defaults.data(forKey: Self.stateKey),
              let s = try? JSONDecoder().decode(AlertState.self, from: data) else { return AlertState() }
        return s
    }

    public func saveState(_ state: AlertState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryAlertStore: AlertStore {
    private let value: Mutex<(settings: AlertSettings?, state: AlertState)>

    public init(settings: AlertSettings? = nil, state: AlertState = AlertState()) { value = Mutex((settings, state)) }

    public func loadSettings(defaults: AlertSettings) -> AlertSettings { value.withLock { $0.settings } ?? defaults }
    public func saveSettings(_ settings: AlertSettings) { value.withLock { $0.settings = settings } }
    public func loadState() -> AlertState { value.withLock { $0.state } }
    public func saveState(_ state: AlertState) { value.withLock { $0.state = state } }
}
