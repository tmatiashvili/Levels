import Foundation

// LIVE-001: the "Live levels" Live Activity. The content-state is shared by the iPhone (which
// updates the activity itself while it runs) and the Mac (which pushes it through the relay
// after enrollment, PUSH-001). It is plain data with no ActivityKit, so the Mac and the tests
// can build it; the `ActivityAttributes` type lives in LevelsWidgetKit (iOS only).
//
// Apple decodes a pushed `content-state` with the default JSON strategies, so every field is
// a plain JSON value: Int levels, Bool flags, Unix seconds as Int64 (a `Date` would be encoded
// as seconds since 2001, which nobody reading the payload expects). No names: those stay in the
// activity's static attributes on the iPhone (ADR-0023 Decision 6).

/// What the Live Activity shows: up to three batteries, in a fixed order.
public struct LiveLevelsState: Codable, Hashable, Sendable {
    /// Which battery a slot is. Raw values are the wire format.
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// The iPhone that runs the activity.
        case iphone
        /// The paired Mac.
        case mac
        /// AirPods reported by the Mac (the lower of the two buds).
        case airpods
    }

    public struct Device: Codable, Hashable, Sendable {
        public var role: Role
        /// 0...100; `nil` = unknown.
        public var level: Int?
        /// Charging or plugged in.
        public var charging: Bool
        /// When this reading was taken, Unix seconds.
        public var updatedAt: Int64

        public init(role: Role, level: Int?, charging: Bool, updatedAt: Int64) {
            self.role = role
            self.level = level.map(DeviceBattery.clampedLevel)
            self.charging = charging
            self.updatedAt = updatedAt
        }

        public var updatedDate: Date { Date(timeIntervalSince1970: TimeInterval(updatedAt)) }
    }

    /// In ``Role`` order, at most one per role. A role with no device is left out.
    public var devices: [Device]

    public init(devices: [Device]) {
        self.devices = Role.allCases.compactMap { role in devices.first { $0.role == role } }
    }

    public func device(_ role: Role) -> Device? { devices.first { $0.role == role } }

    /// The newest reading in the state; `nil` when empty.
    public var newestUpdate: Date? { devices.map(\.updatedAt).max().map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// The default JSON encoding with sorted keys (what the Mac pushes, what tests measure).
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// Builds a ``LiveLevelsState`` from the device list. Pure; the iPhone and the Mac use the same
/// rule, so a pushed state and a local update show the same devices.
public enum LiveLevels {
    /// - Parameters:
    ///   - iphoneID: the iPhone running the activity (its own record).
    ///   - macID: the paired Mac. `nil` (or not in the list): the Mac with the newest reading.
    public static func state(from devices: [DeviceBattery], iphoneID: DeviceID?, macID: DeviceID?) -> LiveLevelsState {
        var out: [LiveLevelsState.Device] = []
        if let iphoneID, let phone = devices.first(where: { $0.id == iphoneID }) {
            out.append(device(.iphone, phone))
        }
        let macs = devices.filter { $0.kind == .mac }
        if let mac = macs.first(where: { $0.id == macID }) ?? macs.max(by: { $0.updatedAt < $1.updatedAt }) {
            out.append(device(.mac, mac))
        }
        if let pods = airpods(devices, preferParent: macID) { out.append(pods) }
        return LiveLevelsState(devices: out)
    }

    /// Per role, the newer of the two readings. The app lays its local state over what the
    /// activity shows, so a local update never takes back a newer level the Mac pushed (R21).
    public static func newest(_ shown: LiveLevelsState?, _ local: LiveLevelsState) -> LiveLevelsState {
        guard let shown else { return local }
        return LiveLevelsState(devices: LiveLevelsState.Role.allCases.compactMap { role in
            switch (shown.device(role), local.device(role)) {
            case let (s?, l?): l.updatedAt >= s.updatedAt ? l : s
            case let (nil, l?): l
            case (_?, nil), (nil, nil): nil  // a device that left the list leaves the activity
            }
        })
    }

    static func charging(_ d: DeviceBattery) -> Bool { d.isCharging || d.isPluggedIn == true }

    static func device(_ role: LiveLevelsState.Role, _ d: DeviceBattery) -> LiveLevelsState.Device {
        .init(role: role, level: d.level, charging: charging(d), updatedAt: unix(d.updatedAt))
    }

    /// One AirPods group: the lower bud (left/right), or the single `main` record; the case
    /// only when no bud reports a level. The group whose Mac is `preferParent` first, then the
    /// newest.
    static func airpods(_ devices: [DeviceBattery], preferParent: DeviceID?) -> LiveLevelsState.Device? {
        let pods = devices.filter { $0.accessory?.kind == .airpods }
        guard !pods.isEmpty else { return nil }
        let groups = Dictionary(grouping: pods) { $0.accessory!.groupID }.values
        let newest: ([DeviceBattery]) -> Date = { $0.map(\.updatedAt).max() ?? .distantPast }
        let chosen = groups.max { a, b in
            let pa = a.contains { $0.accessory?.parentDeviceID == preferParent }
            let pb = b.contains { $0.accessory?.parentDeviceID == preferParent }
            if pa != pb { return !pa }
            return newest(a) < newest(b)
        } ?? []
        let buds = chosen.filter { $0.accessory?.component != .case && $0.level != nil }
        let shown = buds.isEmpty ? chosen.filter { $0.level != nil } : buds
        guard let low = shown.min(by: { ($0.level ?? 0) < ($1.level ?? 0) }) ?? chosen.first else { return nil }
        let charging = (buds.isEmpty ? chosen : buds).contains(where: charging)
        return .init(role: .airpods, level: low.level, charging: charging, updatedAt: unix(newest(chosen)))
    }

    static func unix(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}

/// The rules for when the Live Activity changes, shared by the iPhone's local updates and the
/// Mac's pushes (LIVE-001 R20–R27). Pure; unit-tested.
public enum LiveLevelsPolicy {
    /// iOS ends a Live Activity after 8 hours; the app ends it itself at that point (R7).
    public static let maxDuration: TimeInterval = 8 * 3600
    /// Every update says the content is stale after this long without a newer one (R22).
    public static let staleAfter: TimeInterval = 30 * 60
    /// The Mac pushes at most once per this, except for urgent changes (R24).
    public static let minPushInterval: TimeInterval = 60
    /// The Mac sends at most this many priority-10 pushes per token per hour; the relay's limit
    /// is 12 (PUSH-001 R41). Over it, an urgent change goes as priority 5 (R25).
    public static let maxUrgentPerHour = 10

    /// Whether the activity would look different: a device appeared or left, a whole-percent
    /// level changed, or charging started or stopped. A newer `updatedAt` alone isn't a change.
    public static func isVisibleChange(from old: LiveLevelsState?, to new: LiveLevelsState) -> Bool {
        guard let old else { return true }
        return old.devices.map { Visible($0) } != new.devices.map { Visible($0) }
    }

    /// Plug-in or unplug, a device reaching 100 %, or a level crossing the low-battery threshold
    /// (at or below `threshold`). These go as priority 10 and skip the 60-second gap (R23).
    public static func isUrgent(from old: LiveLevelsState?, to new: LiveLevelsState, threshold: Int) -> Bool {
        guard let old else { return false }
        for d in new.devices {
            guard let o = old.device(d.role) else { continue }
            if o.charging != d.charging { return true }
            if let l = d.level, let ol = o.level {
                if (l <= threshold) != (ol <= threshold) { return true }
                if l == 100, ol < 100 { return true }
            }
        }
        return false
    }

    /// Whether an activity started at `startedAt` must end now (R7).
    public static func hasExpired(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= maxDuration
    }

    /// Why the app can't start the activity (R3). `nil` = it can.
    public enum StartBlocker: Equatable, Sendable {
        /// `LiveActivityAccess.isAllowed()` said no (Free vs Pro, owner decision V).
        case notAllowed
        /// Live Activities are off for Levels in Settings.
        case disabledInSettings
        /// No Mac paired: nothing to show but this iPhone.
        case notPaired
        /// Sample devices are on (DEMO-001): the activity shows only real devices.
        case demo
    }

    public static func startBlocker(isAllowed: Bool, activitiesEnabled: Bool, isPaired: Bool, isDemo: Bool) -> StartBlocker? {
        if !isAllowed { return .notAllowed }
        if !activitiesEnabled { return .disabledInSettings }
        if isDemo { return .demo }
        if !isPaired { return .notPaired }
        return nil
    }

    /// Why a running activity must end now (R7, R8). `nil` = keep it.
    public enum EndReason: Equatable, Sendable { case expired, unpaired }

    public static func endReason(startedAt: Date, now: Date, isPaired: Bool) -> EndReason? {
        if !isPaired { return .unpaired }
        return hasExpired(startedAt: startedAt, now: now) ? .expired : nil
    }

    /// Whether the app should update the activity it shows (R20, R21): on a visible change, or
    /// when the data is newer and the last update is at least ``minPushInterval`` old (so the
    /// stale date moves on without an update per report).
    public static func shouldUpdate(shown: LiveLevelsState?, shownAt: Date?, new: LiveLevelsState, now: Date) -> Bool {
        if isVisibleChange(from: shown, to: new) { return true }
        guard let shown, let shownAt, shown != new else { return false }
        return now.timeIntervalSince(shownAt) >= minPushInterval
    }

    private struct Visible: Equatable {
        var role: LiveLevelsState.Role
        var level: Int?
        var charging: Bool
        init(_ d: LiveLevelsState.Device) { role = d.role; level = d.level; charging = d.charging }
    }
}
