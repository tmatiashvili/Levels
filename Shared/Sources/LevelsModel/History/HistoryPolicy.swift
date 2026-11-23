import Foundation

/// The HIS-001 rules (R3–R7) as pure functions, so they test without files or clocks.
public enum HistoryPolicy {
    /// R5, lead's call 6d.
    public static let retention: TimeInterval = 7 * 24 * 3600
    /// R3: an unchanged candidate closer than this to the last sample is dropped.
    public static let minimumUnchangedInterval: TimeInterval = 10 * 60
    /// R9: samples further apart than this are drawn as a gap (1.5 × the 30-min heartbeat).
    public static let gapThreshold: TimeInterval = 45 * 60
    /// R7: samples further ahead of now than this are dropped.
    public static let futureTolerance: TimeInterval = 5 * 60
    /// R6: per-device cap (one a minute for 7 days is 10,080).
    public static let maxSamples = 10_200

    /// Adds `candidate` to time-ordered `samples` per R3, R4, R7, then prunes (R5, R6).
    public static func appending(_ candidate: HistorySample, to samples: [HistorySample], now: Date) -> [HistorySample] {
        var result = samples
        if candidate.date.timeIntervalSince(now) <= futureTolerance {
            insert(candidate, into: &result)
        }
        return pruned(result, now: now)
    }

    /// Drops samples older than ``retention`` and, past ``maxSamples``, the oldest.
    public static func pruned(_ samples: [HistorySample], now: Date) -> [HistorySample] {
        let oldest = HistorySample.minute(of: now.addingTimeInterval(-retention))
        var result = samples.drop(while: { $0.minute < oldest })
        if result.count > maxSamples { result = result.suffix(maxSamples) }
        return Array(result)
    }

    private static func insert(_ c: HistorySample, into samples: inout [HistorySample]) {
        // Position after every sample at or before c's minute (keeps order after a clock change, R7).
        let index = samples.lastIndex(where: { $0.minute <= c.minute }).map { $0 + 1 } ?? 0
        if index > 0 {
            let previous = samples[index - 1]
            if previous.minute == c.minute {  // same minute: the latest reading wins, flags included
                samples[index - 1] = c
                return
            }
            let interval = TimeInterval(c.minute - previous.minute) * 60
            let isLast = index == samples.count
            if isLast, !previous.endsSegment, previous.hasSameState(as: c), interval < minimumUnchangedInterval {
                if c.endsSegment { samples[index - 1].endsSegment = true }  // R4
                return
            }
        }
        samples.insert(c, at: index)
    }
}
