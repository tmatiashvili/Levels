import LevelsModel
import SwiftUI

/// One device (or grouped accessory) row (R5–R10, R13). One accessibility element.
public struct DeviceRow: View {
    let row: DeviceRowModel
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(row: DeviceRowModel, now: Date = .now) {
        self.row = row
        self.now = now
    }

    /// R10: stacked at `.accessibility1` and larger.
    nonisolated public static func isStacked(_ size: DynamicTypeSize) -> Bool { size >= .accessibility1 }

    private var isStale: Bool { row.freshness(at: now) == .stale }

    /// Ring size in a single row: fits the two text lines, so a row stays about 44 pt tall.
    static let ringSize: CGFloat = 28

    /// macOS shows "This Mac" in the age line, so the tag never truncates the name.
    private static var tagsInAgeLine: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public var body: some View {
        Group {
            if Self.isStacked(dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    HStack(alignment: .center, spacing: 8) { levelArea }
                        .frame(minHeight: Self.ringSize)  // R10: room for the ring at large sizes
                    age
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        age
                    }
                    Spacer(minLength: 8)
                    levelArea
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
    }

    private var title: some View {
        HStack(spacing: 8) {
            DeviceSymbol(row: row)
                .frame(minWidth: 24)
            Text(row.name)
                .lineLimit(Self.isStacked(dynamicTypeSize) ? nil : 1)
            if row.isThisDevice && !Self.tagsInAgeLine {
                Text("This device", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var age: some View {
        HStack(spacing: 4) {
            if row.isThisDevice && Self.tagsInAgeLine {
                Text("This Mac", bundle: .module)
                Text(verbatim: "·").accessibilityHidden(true)
            }
            AgeText(updatedAt: row.readingDate(now: now), now: now)
            if isStale { Image(systemName: "clock").accessibilityHidden(true) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var levelArea: some View {
        if row.isGroup {
            HStack(spacing: 10) {
                ForEach(row.components) { ComponentLevel(record: $0, now: now) }
            }
        } else if let level = row.level {
            LevelView(level: level, isCharging: row.showsChargingBolt(at: now),
                      isLowPowerMode: row.isLowPowerMode, isStale: isStale)
        } else {
            Text(RowText.noBattery())  // R5a: no gauge, no percentage, never low
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Ring, percentage, "Low", bolt and leaf for one level (R5–R7). When stale (R6) the ring is
/// dimmed and the text turns secondary, so it keeps its contrast.
struct LevelView: View {
    let level: Int
    let isCharging: Bool
    let isLowPowerMode: Bool
    let isStale: Bool

    var body: some View {
        let low = DeviceRowModel.isLow(level)
        HStack(spacing: 6) {
            BatteryRing(level: level, isCharging: isCharging, isLow: low, size: DeviceRow.ringSize)
                .opacity(isStale ? 0.45 : 1)
            Text(RowText.percent(level))
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
                .fixedSize()  // R10: the level never truncates
            if low {
                Text(RowText.low()).font(.caption.bold()).foregroundStyle(.red).fixedSize()
            }
            if isCharging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
            if isLowPowerMode { Image(systemName: "leaf.fill").foregroundStyle(.orange) }
        }
    }
}

/// One AirPods component in a grouped row, with its own staleness (R13).
struct ComponentLevel: View {
    let record: DeviceBattery
    let now: Date

    var body: some View {
        let stale = FreshnessRule.of(record, at: now) == .stale
        let low = DeviceRowModel.isLow(record.level)
        VStack(spacing: 2) {
            Text(RowText.componentTitle(record.accessory?.component ?? .main))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let level = record.level {
                BatteryRing(level: level, isCharging: record.isCharging && !stale, isLow: low, size: 24)
                    .opacity(stale ? 0.45 : 1)
                HStack(spacing: 2) {
                    Text(RowText.percent(level)).font(.caption).monospacedDigit().fixedSize()
                        .foregroundStyle(stale ? .secondary : .primary)
                    if low { Text(RowText.low()).font(.caption2.bold()).foregroundStyle(.red).fixedSize() }
                    if stale { Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary) }
                }
            } else {
                Text(verbatim: "–").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
