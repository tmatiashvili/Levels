import Foundation
import LevelsModel

/// The chart's time window (HIS-001 R8): 24 h by default, 7 days as the option.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day, week

    public var id: Self { self }
    public var duration: TimeInterval { self == .day ? 24 * 3600 : HistoryPolicy.retention }
    public var title: String { self == .day ? loc("24 hours") : loc("7 days") }
}

/// One battery's samples for the chart: a device, or one component of an AirPods group.
public struct HistorySeriesInput: Sendable, Equatable {
    public var name: String
    public var samples: [HistorySample]

    public init(name: String, samples: [HistorySample]) {
        self.name = name
        self.samples = samples
    }

    /// The batteries behind a list row: one series, or one per group component in
    /// left, right, case order (owner decision E).
    public static func inputs(for row: DeviceRowModel, samples: [DeviceID: [HistorySample]]) -> [HistorySeriesInput] {
        guard row.isGroup else { return [HistorySeriesInput(name: loc("Level"), samples: samples[row.id] ?? [])] }
        return row.components.map { c in
            HistorySeriesInput(name: componentName(c.accessory?.component ?? .main), samples: samples[c.id] ?? [])
        }
    }

    static func componentName(_ c: AccessoryComponent) -> String {
        switch c {
        case .left: loc("Left")
        case .right: loc("Right")
        case .case: loc("Case")
        case .main: loc("Level")
        }
    }
}

/// Pure transform from samples to what the chart draws (HIS-001 R8–R10): line segments
/// broken at gaps and sleep, charging and Low Power Mode bands, the x domain and the summary.
public struct HistoryChartModel: Equatable, Sendable {
    public struct Point: Hashable, Sendable, Identifiable {
        public var series: String
        public var segment: Int
        public var date: Date
        public var level: Int
        public var id: String { "\(series)#\(segment)#\(date.timeIntervalSinceReferenceDate)" }
        /// Groups points into one polyline per continuous segment (R9).
        public var segmentKey: String { "\(series)#\(segment)" }
    }

    public enum BandKind: Sendable, Hashable { case charging, lowPower }

    public struct Band: Hashable, Sendable, Identifiable {
        public var kind: BandKind
        public var start: Date
        public var end: Date
        public var id: String { "\(kind)#\(start.timeIntervalSinceReferenceDate)" }
    }

    public let seriesNames: [String]
    public let points: [Point]
    public let bands: [Band]
    public let domain: ClosedRange<Date>
    /// Lowest and highest level in the window; `nil` when empty.
    public let low: Int?
    public let high: Int?

    /// R10.
    public var isEmpty: Bool { points.isEmpty }

    public func segments(of series: String) -> [[Point]] {
        Dictionary(grouping: points.filter { $0.series == series }, by: \.segment)
            .sorted { $0.key < $1.key }.map(\.value)
    }

    public init(series: [HistorySeriesInput], range: HistoryRange, now: Date) {
        let start = now.addingTimeInterval(-range.duration)
        domain = start...now
        seriesNames = series.map(\.name)
        var points: [Point] = []
        var charging: [ClosedRange<Date>] = []
        var lowPower: [ClosedRange<Date>] = []
        var levels: [Int] = []
        for input in series {
            // One sample before the window keeps the line continuous into the left edge.
            // Sorted defensively: the store keeps order, but the transform must not draw backwards.
            let visible = input.samples
                .filter { $0.date >= start.addingTimeInterval(-HistoryPolicy.gapThreshold) && $0.date <= now }
                .sorted { $0.minute < $1.minute }
            levels += visible.filter { $0.date >= start }.map(\.level)
            var segment = -1
            var previous: HistorySample?
            var current: [(HistorySample, Date)] = []  // sample, where its state ends
            func closeSegment(end: Date?) {
                guard !current.isEmpty else { return }
                if let end, let last = current.last {
                    current[current.count - 1].1 = end
                    if end > last.0.date {
                        points.append(Point(series: input.name, segment: segment, date: end, level: last.0.level))
                    }
                }
                for (s, until) in current where until > s.date {
                    if s.isCharging { charging.append(s.date...until) }
                    if s.isLowPowerMode { lowPower.append(s.date...until) }
                }
                current = []
            }
            for s in visible {
                let breaks = previous.map { $0.endsSegment || s.date.timeIntervalSince($0.date) > HistoryPolicy.gapThreshold } ?? true
                if breaks {
                    closeSegment(end: nil)
                    segment += 1
                } else if !current.isEmpty {
                    current[current.count - 1].1 = s.date
                }
                current.append((s, s.date))
                points.append(Point(series: input.name, segment: segment, date: s.date, level: s.level))
                previous = s
            }
            // The last segment runs to now only when it is recent and not ended by sleep (R9).
            if let last = previous, !last.endsSegment, now.timeIntervalSince(last.date) <= HistoryPolicy.gapThreshold {
                closeSegment(end: now)
            } else {
                closeSegment(end: nil)
            }
        }
        self.points = points
        bands = Self.merge(charging, kind: .charging, clip: domain) + Self.merge(lowPower, kind: .lowPower, clip: domain)
        low = levels.min()
        high = levels.max()
    }

    /// Unions overlapping or touching spans (an AirPods group charges when any component does) and clips them.
    static func merge(_ spans: [ClosedRange<Date>], kind: BandKind, clip: ClosedRange<Date>) -> [Band] {
        var result: [Band] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let s = max(span.lowerBound, clip.lowerBound), e = min(span.upperBound, clip.upperBound)
            guard e > s else { continue }
            if let last = result.last, s <= last.end {
                result[result.count - 1].end = max(last.end, e)
            } else {
                result.append(Band(kind: kind, start: s, end: e))
            }
        }
        return result
    }

    /// "Low 31 % · high 100 %", or `nil` when empty.
    public var summary: String? {
        guard let low, let high else { return nil }
        return loc("Low \(low) % · high \(high) %")
    }

    /// The level of each series at `date` (nearest point of a segment that covers it), for the hover readout.
    public func levels(at date: Date) -> [(series: String, level: Int)] {
        seriesNames.compactMap { name in
            for seg in segments(of: name) {
                guard let first = seg.first, let last = seg.last, first.date <= date, date <= last.date else { continue }
                let nearest = seg.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }!
                return (name, nearest.level)
            }
            return nil
        }
    }
}
