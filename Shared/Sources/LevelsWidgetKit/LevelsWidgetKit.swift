// LevelsWidgetKit (ADR-0003, UI-003 Design, UI-004 R11–R14): the shared device widget,
// its timeline provider and family views. Reads the App Group snapshot cache only and never
// fetches (ADR-0006, SYNC-001 R14).
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import WidgetKit

/// One widget timeline entry (UI-003 Design, without the configuration choice for now).
public struct DeviceEntry: TimelineEntry, Sendable {
    public let date: Date
    /// `nil` = no cache yet ("Open Levels to start", ADR-0017 §6).
    public let snapshot: SnapshotFile?
    public let rows: [DeviceRowModel]

    public init(date: Date, snapshot: SnapshotFile?, preferences: DisplayPreferences) {
        self.date = date
        self.snapshot = snapshot
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

    public var isICloudOff: Bool {
        snapshot?.syncStatus == .signedOut || snapshot?.syncStatus == .restricted
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
    public static func entries(snapshot: SnapshotFile?, preferences: DisplayPreferences, now: Date) -> [DeviceEntry] {
        let first = DeviceEntry(date: now, snapshot: snapshot, preferences: preferences)
        return entryDates(rows: first.rows, now: now).map {
            $0 == now ? first : DeviceEntry(date: $0, snapshot: snapshot, preferences: preferences)
        }
    }
}

/// Reads the cache synchronously from the App Group named in the extension's Info.plist.
public struct DevicesProvider: TimelineProvider {
    public init() {}

    static func load(now: Date) -> [DeviceEntry] {
        let group = LevelsAppConfig.appGroupID
        let snapshot = group.flatMap(SnapshotCache.init(appGroupID:))?.read()
        let prefs = UserDefaultsDisplayPreferencesStore(suiteName: group).load()
        return DevicesTimeline.entries(snapshot: snapshot, preferences: prefs, now: now)
    }

    public func placeholder(in context: Context) -> DeviceEntry { Self.sample(now: .now) }

    public func getSnapshot(in context: Context, completion: @escaping (DeviceEntry) -> Void) {
        completion(context.isPreview ? Self.sample(now: .now) : Self.load(now: .now)[0])
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<DeviceEntry>) -> Void) {
        let now = Date()
        let entries = Self.load(now: now)
        completion(Timeline(entries: entries, policy: DevicesTimeline.policy(entryCount: entries.count, now: now)))
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
/// the platform: on the Mac `systemSmall` and `systemMedium` (UI-004 R11, `systemLarge` not
/// yet) and the small default excludes this Mac (UI-004 R12).
public struct LevelsDevicesWidget: Widget {
    public static let kind = "LevelsDevices"

    #if os(macOS)
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium]
    static let excludesThisDeviceFromLowest = true
    #else
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium]
    static let excludesThisDeviceFromLowest = false
    #endif

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DevicesProvider()) { entry in
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
                MediumDevicesView(entry: entry)
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
        if let row = entry.lowest(excludingThisDevice: excludesThisDevice) ?? entry.rows.first {
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

    var body: some View {
        let shown = Array(entry.rows.prefix(4))
        let oldest = shown.map { $0.readingDate(now: entry.date) }.min() ?? entry.date
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(shown) { row in
                    Link(destination: LevelsAppConfig.deviceURL(row.id)) {
                        VStack(spacing: 4) {
                            DeviceSymbol(row: row).widgetAccentable()
                            WidgetLevel(row: row, now: entry.date, ringSize: 44, font: .caption.weight(.semibold))
                            Text(Self.shortName(row.name)).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                    }
                }
            }
            AgeLine(date: oldest, stale: shown.contains { $0.freshness(at: entry.date) == .stale })
        }
    }

    /// Builder's call (UI-003 Design): the first word of the name.
    static func shortName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
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
                BatteryRing(level: level, isCharging: row.showsChargingBolt(at: now), isLow: row.isLow)
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
