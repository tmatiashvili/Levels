import Foundation

/// The version-1 history file (HIS-001 Design): version byte, base minute (UInt32),
/// then 4 bytes per sample: minutes after base (UInt16), level (UInt8), flags (UInt8).
/// Big-endian.
public enum HistoryCodec {
    public static let version: UInt8 = 1
    public static let headerSize = 5
    public static let sampleSize = 4

    public enum DecodeError: Error, Equatable {
        case empty, unsupportedVersion(UInt8), truncated, badOffset
    }

    private enum Flag {
        static let charging: UInt8 = 1 << 0
        static let pluggedIn: UInt8 = 1 << 1
        static let lowPower: UInt8 = 1 << 2
        static let endsSegment: UInt8 = 1 << 3
    }

    /// Encodes time-ordered samples. Samples more than UInt16.max minutes after the first
    /// can't be stored and are dropped (pruning keeps the span at 7 days).
    public static func encode(_ samples: [HistorySample]) -> Data {
        var data = Data([version])
        let base = samples.first.map { UInt32(clamping: $0.minute) } ?? 0
        append(base, to: &data)
        for s in samples {
            let offset = s.minute - Int(base)
            guard offset >= 0, offset <= Int(UInt16.max) else { continue }
            append(UInt16(offset), to: &data)
            var flags: UInt8 = 0
            if s.isCharging { flags |= Flag.charging }
            if s.isPluggedIn { flags |= Flag.pluggedIn }
            if s.isLowPowerMode { flags |= Flag.lowPower }
            if s.endsSegment { flags |= Flag.endsSegment }
            data.append(UInt8(clamping: s.level))
            data.append(flags)
        }
        return data
    }

    public static func decode(_ data: Data) throws(DecodeError) -> [HistorySample] {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { throw .empty }
        guard first == version else { throw .unsupportedVersion(first) }
        guard bytes.count >= headerSize, (bytes.count - headerSize) % sampleSize == 0 else { throw .truncated }
        let base = bytes[1...4].reduce(0) { $0 << 8 | Int($1) }
        var samples: [HistorySample] = []
        samples.reserveCapacity((bytes.count - headerSize) / sampleSize)
        var i = headerSize
        var lastMinute = Int.min
        while i < bytes.count {
            let offset = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            let level = Int(bytes[i + 2]), flags = bytes[i + 3]
            let minute = base + offset
            guard minute >= lastMinute else { throw .badOffset }
            lastMinute = minute
            samples.append(HistorySample(minute: minute, level: level,
                                         isCharging: flags & Flag.charging != 0,
                                         isPluggedIn: flags & Flag.pluggedIn != 0,
                                         isLowPowerMode: flags & Flag.lowPower != 0,
                                         endsSegment: flags & Flag.endsSegment != 0))
            i += sampleSize
        }
        return samples
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
