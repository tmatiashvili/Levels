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

    /// UI-003 R2 "Lowest battery", over every shown row. This device is a candidate too
    /// (owner decision L: Mac widgets include this Mac, UI-004 R12).
    public var lowest: DeviceRowModel? { MenuBarLabelModel.lowest(rows, now: date) }

    /// What a single-device family shows: the configured device while it is still shown,
    /// else "Lowest battery" (UI-003 R1, edge case "selected device later hidden or deleted").
    public var singleDevice: DeviceRowModel? {
        if let selection, let row = rows.first(where: { $0.id == selection }) { return row }
        return lowest ?? rows.first
    }

    /// `systemLarge` content (UI-003 R3, R4, R8), in UI-001 order: this device first.
    public var largeList: LargeList { LargeList(rows: rows) }

    /// `systemMedium` content: up to 4 rows in UI-001 order (UI-003 R3).
    public var mediumRows: [DeviceRowModel] { Array(rows.prefix(4)) }

    /// True when the only shown device is this one (UI-003 R8 "Other devices appear…").
    public var isOnlyThisDevice: Bool { rows.count == 1 && rows[0].isThisDevice }

    public var isICloudOff: Bool {
        #if os(iOS)
        false  // the iPhone build is hub mode: `.restricted` means Local Network off (NET-004 R12)
        #else
        snapshot?.syncStatus == .signedOut || snapshot?.syncStatus == .restricted
        #endif
    }

    /// NET-004 R12: no Mac pairing ("Open Levels to connect your Mac").
    public var isNotPaired: Bool { snapshot?.syncStatus == .notPaired }

    /// NET-004 R13: the last good contact when the cache says away; `nil` otherwise.
    public var awayFooterDate: Date?? {
        if case .awayFromHub(let at)? = snapshot?.syncStatus { return .some(at ?? snapshot?.lastFetchAt) }
        return nil
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

/// NET-004 R14 variant B (lead's call 29: A + B): when the cache is older than 15 minutes
/// the widget fetches from the Mac itself. Pure planning, unit-tested with a fake fetch.
public enum HubWidgetPlan {
    /// The cache counts as fresh this long after `lastFetchAt`.
    public static let freshFor: TimeInterval = 15 * 60
    /// Reload after a good fetch (or a fresh cache). 30 minutes (48 a day) stays inside the
    /// WidgetKit reload budget; 15 minutes (96 a day) did not.
    public static let afterSuccess: TimeInterval = 30 * 60
    /// Reload after a failed fetch.
    public static let afterFailure: TimeInterval = 60 * 60

    /// What a widget fetch from the Mac gave.
    public enum FetchResult: Sendable {
        /// The merged file (already written to the cache when the App Group exists).
        case fetched(SnapshotFile)
        /// The Mac was not reached in time: show the cache, marked away.
        case failed
        /// The Mac was reached but answered with an error (busy, other version, refused
        /// key): show the cache as it is, not away, and try again on the normal schedule.
        case macError
        /// The widget can't fetch at all (no pairing readable from the shared Keychain):
        /// fall back to variant A (lead's call 29).
        case unavailable
    }

    /// A fetch from the Mac, given the cached file. Must end within 4 s.
    public typealias Fetch = @Sendable (SnapshotFile?) async -> FetchResult

    public enum Outcome: Equatable, Sendable { case variantA, cacheFresh, fetched, failed, macError }

    /// Picks the snapshot to show and the next reload date. `nil` reload = variant A's policy.
    public static func resolve(cached: SnapshotFile?, now: Date, fetch: Fetch?) async
        -> (snapshot: SnapshotFile?, reloadAt: Date?, outcome: Outcome) {
        guard let fetch, let cached, cached.syncStatus != .notPaired else { return (cached, nil, .variantA) }
        if let last = cached.lastFetchAt, now.timeIntervalSince(last) < freshFor, now >= last {
            return (cached, last.addingTimeInterval(afterSuccess), .cacheFresh)
        }
        switch await fetch(cached) {
        case .fetched(let fetched): return (fetched, now.addingTimeInterval(afterSuccess), .fetched)
        case .unavailable: return (cached, nil, .variantA)
        case .macError: return (cached, now.addingTimeInterval(afterSuccess), .macError)
        case .failed: break
        }
        var away = cached
        if case .awayFromHub = cached.syncStatus {} else {
            away.syncStatus = .awayFromHub(lastContactAt: cached.lastFetchAt)
        }
        return (away, now.addingTimeInterval(afterFailure), .failed)
    }
}

/// Reads the cache synchronously from the App Group named in the extension's Info.plist.
/// With a `fetch` (iPhone variant B) it may also ask the Mac when the cache is old.
public struct DevicesProvider: AppIntentTimelineProvider {
    let fetch: HubWidgetPlan.Fetch?

    public init(fetch: HubWidgetPlan.Fetch? = nil) { self.fetch = fetch }

    static func cached() -> (SnapshotFile?, DisplayPreferences) {
        let group = LevelsAppConfig.appGroupID
        let snapshot = group.flatMap(SnapshotCache.init(appGroupID:))?.read()
        return (snapshot, UserDefaultsDisplayPreferencesStore(suiteName: group).load())
    }

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
        let selection = configuration.device?.deviceID
        guard let fetch else {
            let entries = Self.load(now: now, selection: selection)
            return Timeline(entries: entries, policy: DevicesTimeline.policy(entryCount: entries.count, now: now))
        }
        let (cached, prefs) = Self.cached()
        let plan = await HubWidgetPlan.resolve(cached: cached, now: now, fetch: fetch)
        var entries = DevicesTimeline.entries(snapshot: plan.snapshot, preferences: prefs, now: now, selection: selection)
        guard let reloadAt = plan.reloadAt else {
            return Timeline(entries: entries, policy: DevicesTimeline.policy(entryCount: entries.count, now: now))
        }
        entries = entries.filter { $0.date < reloadAt }  // ADR-0017 stale entries before the reload
        return Timeline(entries: entries.isEmpty ? [DeviceEntry(date: now, snapshot: plan.snapshot, preferences: prefs,
                                                                selection: selection)] : entries,
                        policy: .after(reloadAt))
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
/// the platform: on the Mac `systemSmall`, `systemMedium` and `systemLarge` (UI-004 R11).
/// Every family includes this device (UI-004 R12, owner decision L).
public struct LevelsDevicesWidget: Widget {
    public static let kind = "LevelsDevices"

    #if os(macOS)
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    #else
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium]
    #endif

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectDeviceIntent.self, provider: DevicesProvider()) { entry in
            DevicesWidgetView(entry: entry)
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
    @Environment(\.widgetFamily) private var family

    public init(entry: DeviceEntry) {
        self.entry = entry
    }

    public var body: some View {
        if entry.snapshot == nil || entry.rows.isEmpty || entry.isNotPaired {  // NET-004 R12
            EmptyWidgetView(entry: entry)
        } else {
            switch family {
            case .systemMedium:
                MediumDevicesView(entry: entry)
            #if !os(watchOS)
            case .systemLarge:
                LargeDevicesView(entry: entry)
            #endif
            default:
                SmallDeviceView(entry: entry)
            }
        }
    }
}

/// "Open Levels to start" (ADR-0017 §6, UI-003 R8). Tapping opens the app.
struct EmptyWidgetView: View {
    let entry: DeviceEntry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isICloudOff ? "icloud.slash" : entry.isNotPaired ? "macbook.and.iphone" : MenuBarLabelModel.appSymbol)
                .font(.title2)
                .widgetAccentable()
            Text(entry.isICloudOff ? String(localized: "iCloud off")
                 : entry.isNotPaired ? String(localized: "Open Levels to connect your Mac")
                 : String(localized: "Open Levels to start"))
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .widgetURL(LevelsAppConfig.listURL)
    }
}

/// `systemSmall`: one device, as a large ring with its symbol inside, the percentage, its
/// name and, when relevant, a status line (UI-003 R3, owner's widget review).
struct SmallDeviceView: View {
    let entry: DeviceEntry

    var body: some View {
        if let row = entry.singleDevice {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                DeviceRing(row: row, now: entry.date, metrics: .small)
                Spacer(minLength: 6)
                PercentText(row: row, now: entry.date,
                            font: .system(.title2, design: .rounded).weight(.semibold))
                ShortName(row: row, font: .caption.weight(.medium))
                    .foregroundStyle(.secondary)
                StatusLine(status: WidgetStatus.of(row, now: entry.date))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
            .widgetURL(LevelsAppConfig.deviceURL(row.id))  // UI-003 R7, UI-004 R14
        }
    }
}

/// `systemMedium`: up to 4 devices as equal columns (ring with symbol, percentage, name), UI-001
/// order. A status line shows under a device only when it has something to say; then every
/// column keeps that line's height so rings and text stay level (owner's widget review). Each
/// column is a `Link` to its device (UI-003 R7).
struct MediumDevicesView: View {
    let entry: DeviceEntry

    var body: some View {
        let shown = entry.mediumRows
        let anyStatus = shown.contains { WidgetStatus.of($0, now: entry.date) != nil }
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 6) {
                ForEach(shown) { row in
                    Link(destination: LevelsAppConfig.deviceURL(row.id)) {
                        DeviceColumn(row: row, now: entry.date, metrics: .medium,
                                     percentFont: .system(.subheadline, design: .rounded).weight(.semibold),
                                     nameFont: .caption2, reserveStatus: anyStatus)
                            .foregroundStyle(.primary)  // accented mode must not tint links blue
                    }
                }
            }
            Spacer(minLength: 0)
            if let away = entry.awayFooterDate {
                AwayFooter(lastContact: away)
            } else if entry.isOnlyThisDevice {
                OnlyThisDeviceHint()
            }
        }
    }
}

/// UI-003 R8 / NET-004 R12: why only this device is shown.
struct OnlyThisDeviceHint: View {
    var body: some View {
        Group {
            #if os(iOS)
            Text(String(localized: "Your Mac appears when it connects"))
            #else
            Text(String(localized: "Other devices appear when they run Levels"))
            #endif
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// NET-004 R13: "Away from Mac · <age of lastFetchAt>", self-updating. Medium and large only.
struct AwayFooter: View {
    let lastContact: Date?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "wifi.slash")
            if let lastContact {
                Text("Away from Mac · \(Text(.currentDate, format: .reference(to: lastContact, allowedFields: [.minute, .hour, .day])))")
            } else {
                Text("Away from Mac")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// `systemLarge`: up to 8 devices as rows (symbol + name, bar + %, age), UI-001 order, "+N more"
/// when cut (UI-003 R3, R4). Each row is a `Link` to its device (UI-003 R7, UI-004 R14).
public struct LargeDevicesView: View {
    let entry: DeviceEntry

    public init(entry: DeviceEntry) {
        self.entry = entry
    }

    public var body: some View {
        let list = entry.largeList
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
                OnlyThisDeviceHint().padding(.top, 6)  // NET-004 R12
            }
            Spacer(minLength: 0)
            if let away = entry.awayFooterDate { AwayFooter(lastContact: away) }
        }
        .widgetURL(LevelsAppConfig.listURL)  // taps outside a row open the list
    }
}

/// One `systemLarge` row: small ring with the symbol, name and (when relevant) status, and the
/// percentage at the trailing edge (owner's widget review).
struct LargeDeviceRow: View {
    let row: DeviceRowModel
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            DeviceRing(row: row, now: now, metrics: .large)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.subheadline.weight(.medium)).lineLimit(1)
                StatusLine(status: WidgetStatus.of(row, now: now), alignment: .leading)
            }
            Spacer(minLength: 6)
            PercentText(row: row, now: now, font: .system(.subheadline, design: .rounded).weight(.semibold))
        }
        .frame(minHeight: 34)
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
    }
}
