// LevelsWidgetKit (ADR-0003, UI-003 Design, UI-004 R11–R14): the shared device widget,
// its timeline provider and family views. Reads the App Group snapshot cache only and never
// fetches (ADR-0006, SYNC-001 R14).
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import WidgetKit

/// One widget timeline entry (UI-003 Design).
public struct DeviceEntry: TimelineEntry, Sendable {
    public let date: Date
    /// `nil` = no cache yet ("Open Levels to start", ADR-0017 §6).
    public let snapshot: SnapshotFile?
    public let rows: [DeviceRowModel]
    /// The configured device (UI-003 R1); `nil` = "Lowest battery".
    public let selection: DeviceID?

    public init(date: Date, snapshot: SnapshotFile?, preferences: DisplayPreferences, selection: DeviceID? = nil) {
        self.date = date
        self.snapshot = snapshot
        self.selection = selection
        rows = snapshot.map {
            DeviceRows(devices: $0.devices, thisDeviceID: $0.ownDeviceID, preferences: preferences, now: date).rows
        } ?? []
    }

    /// UI-003 R2 "Lowest battery". `excludingThisDevice` is the Mac default (UI-004 R12); when
    /// no other device has a level, this device is shown instead (local-only build).
    public func lowest(excludingThisDevice: Bool) -> DeviceRowModel? {
        let pool = excludingThisDevice ? rows.filter { !$0.isThisDevice } : rows
        return MenuBarLabelModel.lowest(pool, now: date)
            ?? (excludingThisDevice ? MenuBarLabelModel.lowest(rows, now: date) : nil)
    }

    /// What a single-device family shows: the configured device while it is still shown,
    /// else "Lowest battery" (UI-003 R1, edge case "selected device later hidden or deleted").
    public func singleDevice(excludingThisDevice: Bool) -> DeviceRowModel? {
        if let selection, let row = rows.first(where: { $0.id == selection }) { return row }
        return lowest(excludingThisDevice: excludingThisDevice) ?? rows.first
    }

    /// Rows for the list families. On the Mac this Mac is left out (macOS shows its battery
    /// already, UI-004 R1/R12) unless it is the only device.
    public func listRows(excludingThisDevice: Bool) -> [DeviceRowModel] {
        guard excludingThisDevice else { return rows }
        let others = rows.filter { !$0.isThisDevice }
        return others.isEmpty ? rows : others
    }

    /// `systemLarge` content (UI-003 R3, R4, R8).
    public func largeList(excludingThisDevice: Bool) -> LargeList {
        LargeList(rows: listRows(excludingThisDevice: excludingThisDevice))
    }

    /// `systemMedium` content: up to 4 rows (UI-003 R3).
    public func mediumRows(excludingThisDevice: Bool) -> [DeviceRowModel] {
        Array(listRows(excludingThisDevice: excludingThisDevice).prefix(4))
    }

    /// True when the only shown device is this one (UI-003 R8 "Other devices appear…").
    public var isOnlyThisDevice: Bool { rows.count == 1 && rows[0].isThisDevice }

    public var isICloudOff: Bool {
        snapshot?.syncStatus == .signedOut || snapshot?.syncStatus == .restricted
    }
}

/// `systemLarge` rows: up to ``limit`` in UI-001 order, then "+N more" (UI-003 R3, AC3). Pure.
public struct LargeList: Equatable, Sendable {
    public static let limit = 8
    public let shown: [DeviceRowModel]
    /// Rows left out; "+N more" when > 0.
    public let moreCount: Int

    public init(rows: [DeviceRowModel], limit: Int = LargeList.limit) {
        shown = Array(rows.prefix(limit))
        moreCount = max(0, rows.count - limit)
    }
}

/// ADR-0017 rule 3 timeline planning. Pure, unit-tested.
public enum DevicesTimeline {
    public static let minimumSpacing: TimeInterval = 5 * 60
    public static let horizon: TimeInterval = 24 * 60 * 60
    public static let safetyReload: TimeInterval = 6 * 60 * 60

    /// Entry dates: `now`, then each future stale moment of a shown row within 24 h,
    /// dropping any closer than 5 min to the previous one.
    public static func entryDates(rows: [DeviceRowModel], now: Date) -> [Date] {
        let stale = rows.flatMap(\.records).map(FreshnessRule.staleDate(for:))
            .filter { $0 > now && $0 <= now.addingTimeInterval(horizon) }
            .sorted()
        var dates = [now]
        for d in stale where d.timeIntervalSince(dates.last!) >= minimumSpacing { dates.append(d) }
        return dates
    }

    /// `.atEnd` when there are future entries, else `.after(now + 6 h)`.
    public static func policy(entryCount: Int, now: Date) -> TimelineReloadPolicy {
        entryCount > 1 ? .atEnd : .after(now.addingTimeInterval(safetyReload))
    }

    /// Builds the entries for one snapshot.
    public static func entries(snapshot: SnapshotFile?, preferences: DisplayPreferences, now: Date,
                               selection: DeviceID? = nil) -> [DeviceEntry] {
        let first = DeviceEntry(date: now, snapshot: snapshot, preferences: preferences, selection: selection)
        return entryDates(rows: first.rows, now: now).map {
            $0 == now ? first : DeviceEntry(date: $0, snapshot: snapshot, preferences: preferences, selection: selection)
        }
    }
}

/// Reads the cache synchronously from the App Group named in the extension's Info.plist.
public struct DevicesProvider: AppIntentTimelineProvider {
    public init() {}

    static func load(now: Date, selection: DeviceID? = nil) -> [DeviceEntry] {
        let group = LevelsAppConfig.appGroupID
        let snapshot = group.flatMap(SnapshotCache.init(appGroupID:))?.read()
        let prefs = UserDefaultsDisplayPreferencesStore(suiteName: group).load()
        return DevicesTimeline.entries(snapshot: snapshot, preferences: prefs, now: now, selection: selection)
    }

    public func placeholder(in context: Context) -> DeviceEntry { Self.sample(now: .now) }

    public func snapshot(for configuration: SelectDeviceIntent, in context: Context) async -> DeviceEntry {
        context.isPreview ? Self.sample(now: .now) : Self.load(now: .now, selection: configuration.device?.deviceID)[0]
    }

    public func timeline(for configuration: SelectDeviceIntent, in context: Context) async -> Timeline<DeviceEntry> {
        let now = Date()
        let entries = Self.load(now: now, selection: configuration.device?.deviceID)
        return Timeline(entries: entries, policy: DevicesTimeline.policy(entryCount: entries.count, now: now))
    }

    /// Gallery and placeholder data, never the cache (UI-003 Design).
    public static func sample(now: Date) -> DeviceEntry {
        let mac = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let devices = [
            DeviceBattery(id: mac, name: "MacBook", kind: .mac, level: 76, isCharging: true, isPluggedIn: true, updatedAt: now - 120),
            DeviceBattery(id: DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), name: "iPhone",
                          kind: .iphone, level: 18, isCharging: false, updatedAt: now - 540),
            DeviceBattery(id: DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!), name: "Watch",
                          kind: .watch, level: 71, isCharging: false, updatedAt: now - 3600),
        ]
        return DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: mac, devices: devices), preferences: DisplayPreferences())
    }
}

/// The device widget (kind `"LevelsDevices"`). Families and the "Lowest battery" rule follow
/// the platform: on the Mac `systemSmall`, `systemMedium` and `systemLarge` (UI-004 R11) and
/// the small default excludes this Mac (UI-004 R12).
public struct LevelsDevicesWidget: Widget {
    public static let kind = "LevelsDevices"

    #if os(macOS)
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    static let excludesThisDeviceFromLowest = true
    #else
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium]
    static let excludesThisDeviceFromLowest = false
    #endif

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectDeviceIntent.self, provider: DevicesProvider()) { entry in
            DevicesWidgetView(entry: entry, excludesThisDeviceFromLowest: Self.excludesThisDeviceFromLowest)
                .containerBackground(.fill.tertiary, for: .widget)  // UI-003 R10
        }
        .configurationDisplayName(Text("Battery Levels"))
        .description(Text("See the battery of all your devices."))
        .supportedFamilies(Self.families)
    }
}

/// Picks the family view.
public struct DevicesWidgetView: View {
    let entry: DeviceEntry
    let excludesThisDeviceFromLowest: Bool
    @Environment(\.widgetFamily) private var family

    public init(entry: DeviceEntry, excludesThisDeviceFromLowest: Bool) {
        self.entry = entry
        self.excludesThisDeviceFromLowest = excludesThisDeviceFromLowest
    }

    public var body: some View {
        if entry.snapshot == nil || entry.rows.isEmpty {
            EmptyWidgetView(entry: entry)
        } else {
            switch family {
            case .systemMedium:
                MediumDevicesView(entry: entry, excludesThisDevice: excludesThisDeviceFromLowest)
            #if !os(watchOS)
            case .systemLarge:
                LargeDevicesView(entry: entry, excludesThisDevice: excludesThisDeviceFromLowest)
            #endif
            default:
                SmallDeviceView(entry: entry, excludesThisDevice: excludesThisDeviceFromLowest)
            }
        }
    }
}

/// "Open Levels to start" (ADR-0017 §6, UI-003 R8). Tapping opens the app.
struct EmptyWidgetView: View {
    let entry: DeviceEntry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isICloudOff ? "icloud.slash" : MenuBarLabelModel.appSymbol)
                .font(.title2)
                .widgetAccentable()
            Text(entry.isICloudOff ? String(localized: "iCloud off") : String(localized: "Open Levels to start"))
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .widgetURL(LevelsAppConfig.listURL)
    }
}

/// `systemSmall`: one device, symbol + name, large ring with %, age (UI-003 R3).
struct SmallDeviceView: View {
    let entry: DeviceEntry
    let excludesThisDevice: Bool

    var body: some View {
        if let row = entry.singleDevice(excludingThisDevice: excludesThisDevice) {
            let stale = row.freshness(at: entry.date) == .stale
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    DeviceSymbol(row: row).widgetAccentable()
                    Text(row.name).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    WidgetLevel(row: row, now: entry.date, ringSize: 64, font: .title3)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                AgeLine(date: row.readingDate(now: entry.date), stale: stale)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
            .widgetURL(LevelsAppConfig.deviceURL(row.id))  // UI-003 R7, UI-004 R14
        }
    }
}

/// `systemMedium`: up to 4 devices in a row of rings, one shared age line for the oldest
/// shown reading (UI-003 R3). Each item is a `Link` to its device (UI-003 R7).
struct MediumDevicesView: View {
    let entry: DeviceEntry
    /// The Mac leaves itself out (UI-004 R12), so it doesn't use one of the 4 slots.
    let excludesThisDevice: Bool

    var body: some View {
        let shown = entry.mediumRows(excludingThisDevice: excludesThisDevice)
        let oldest = shown.map { $0.readingDate(now: entry.date) }.min() ?? entry.date
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(shown) { row in
                    Link(destination: LevelsAppConfig.deviceURL(row.id)) {
                        VStack(spacing: 4) {
                            DeviceSymbol(row: row).widgetAccentable()
                            WidgetLevel(row: row, now: entry.date, ringSize: 44, font: .caption.weight(.semibold))
                            Text(row.name).font(.caption2)  // full name; tail-truncated if it won't fit
                                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                        .foregroundStyle(.primary)  // accented mode must not tint links blue
                    }
                }
            }
            AgeLine(date: oldest, stale: shown.contains { $0.freshness(at: entry.date) == .stale })
        }
    }
}

/// `systemLarge`: up to 8 devices as rows (symbol + name, bar + %, age), UI-001 order, "+N more"
/// when cut (UI-003 R3, R4). Each row is a `Link` to its device (UI-003 R7, UI-004 R14).
public struct LargeDevicesView: View {
    let entry: DeviceEntry
    /// The Mac leaves itself out (UI-004 R12) unless it is the only device.
    let excludesThisDevice: Bool

    public init(entry: DeviceEntry, excludesThisDevice: Bool) {
        self.entry = entry
        self.excludesThisDevice = excludesThisDevice
    }

    public var body: some View {
        let list = entry.largeList(excludingThisDevice: excludesThisDevice)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Battery Levels").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if entry.isICloudOff {  // UI-003 R8: badge plus the cached rows
                    Label(String(localized: "iCloud off"), systemImage: "icloud.slash")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)
            ForEach(list.shown) { row in
                Link(destination: LevelsAppConfig.deviceURL(row.id)) {
                    LargeDeviceRow(row: row, now: entry.date)
                        .foregroundStyle(.primary)  // accented mode must not tint links blue
                }
                if row.id != list.shown.last?.id { Divider() }
            }
            if list.moreCount > 0 {
                Text(String(localized: "+\(list.moreCount) more"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else if entry.isOnlyThisDevice {
                Text(String(localized: "Other devices appear when they run Levels"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .widgetURL(LevelsAppConfig.listURL)  // taps outside a row open the list
    }
}

/// One `systemLarge` row: compact form of the UI-001 row, with the widget age text (ADR-0017).
struct LargeDeviceRow: View {
    let row: DeviceRowModel
    let now: Date

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        HStack(spacing: 8) {
            DeviceSymbol(row: row).widgetAccentable().frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.caption.weight(.medium)).lineLimit(1)
                AgeLine(date: row.readingDate(now: now), stale: stale)
            }
            Spacer(minLength: 6)
            if let level = row.level {
                HStack(spacing: 5) {
                    if row.isLow { Text(RowText.low()).font(.caption2.bold()).foregroundStyle(.red) }
                    if row.showsChargingBolt(at: now) { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
                    LevelBar(level: level, isLow: row.isLow).frame(width: 64, height: 6)
                    Text(RowText.percent(level)).font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .opacity(stale ? 0.5 : 1)  // UI-001 R6
            } else {
                Text(RowText.noBattery()).font(.caption2).foregroundStyle(.secondary)  // UI-001 R5a
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
    }
}

/// A ring drawn at any size, with no label of its own: the percentage is shown once, by the
/// caller. (`BatteryRing`'s `.accessoryCircularCapacity` gauge has a fixed size and its own label.)
struct WidgetRing: View {
    let level: Int
    let isCharging: Bool
    let isLow: Bool

    var body: some View {
        let width = 5.0
        ZStack {
            Circle().stroke(.quaternary, lineWidth: width)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(level, 0), 100)) / 100)
                .stroke(isCharging ? Color.green : isLow ? Color.red : Color.primary,
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(width / 2)
        .accessibilityHidden(true)
    }
}

/// Horizontal capacity bar for `systemLarge` rows; the fill is accentable (UI-003 R9).
struct LevelBar: View {
    let level: Int
    let isLow: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(isLow ? Color.red : Color.green)
                    .frame(width: max(geo.size.height, geo.size.width * CGFloat(min(max(level, 0), 100)) / 100))
                    .widgetAccentable()
            }
        }
        .accessibilityHidden(true)
    }
}

/// Ring + percentage, or "no battery" (UI-001 R5a); dimmed when stale (R6).
struct WidgetLevel: View {
    let row: DeviceRowModel
    let now: Date
    let ringSize: CGFloat
    let font: Font

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        if let level = row.level {
            ZStack {
                WidgetRing(level: level, isCharging: row.showsChargingBolt(at: now), isLow: row.isLow)
                    .frame(width: ringSize, height: ringSize)
                VStack(spacing: 0) {
                    Text(RowText.percent(level)).font(font).monospacedDigit().minimumScaleFactor(0.6)
                    if row.isLow { Text(RowText.low()).font(.caption2.bold()) }
                    else if row.showsChargingBolt(at: now) { Image(systemName: "bolt.fill").font(.caption2) }
                }
            }
            .opacity(stale ? 0.5 : 1)
        } else {
            Text(RowText.noBattery()).font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

/// Self-updating age text (ADR-0017 rule 2) with the stale `clock` badge (rule 5).
struct AgeLine: View {
    let date: Date
    let stale: Bool

    var body: some View {
        HStack(spacing: 3) {
            if stale { Image(systemName: "clock") }
            Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day]))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
