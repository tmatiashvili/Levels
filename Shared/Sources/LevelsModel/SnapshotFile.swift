import Foundation

/// Result of the last zone fetch.
public enum FetchOutcome: Sendable, Equatable, Codable {
    case success
    case failed(reason: String)
}

/// Contents of `snapshot.json` in the App Group container (ADR-0009, SYNC-002 R11).
public struct SnapshotFile: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// This device's ID, so widgets can mark "this device".
    public var ownDeviceID: DeviceID?
    /// SHA-256 hex of the CloudKit user record name; a change means a different account.
    public var accountFingerprint: String?
    /// Account for which zone and subscription were saved (SYNC-001 R3).
    public var bootstrappedFingerprint: String?
    /// Last status from `BatterySyncService`, for widgets (ADR-0017 §6).
    public var syncStatus: SyncStatus?
    public var lastFetchAt: Date?
    public var lastFetchOutcome: FetchOutcome?
    /// Known batteries, sorted by kind, then name.
    public var devices: [DeviceBattery]
    /// Last accepted upload per own record (ADR-0008). Encodes as an object keyed by record name.
    public var lastWritten: [DeviceID: DeviceBattery]

    public init(
        formatVersion: Int = SnapshotFile.currentFormatVersion,
        ownDeviceID: DeviceID? = nil,
        accountFingerprint: String? = nil,
        bootstrappedFingerprint: String? = nil,
        syncStatus: SyncStatus? = nil,
        lastFetchAt: Date? = nil,
        lastFetchOutcome: FetchOutcome? = nil,
        devices: [DeviceBattery] = [],
        lastWritten: [DeviceID: DeviceBattery] = [:]
    ) {
        self.formatVersion = formatVersion
        self.ownDeviceID = ownDeviceID
        self.accountFingerprint = accountFingerprint
        self.bootstrappedFingerprint = bootstrappedFingerprint
        self.syncStatus = syncStatus
        self.lastFetchAt = lastFetchAt
        self.lastFetchOutcome = lastFetchOutcome
        self.devices = Self.sorted(devices)
        self.lastWritten = lastWritten
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, ownDeviceID, accountFingerprint, bootstrappedFingerprint, syncStatus
        case lastFetchAt, lastFetchOutcome, devices, lastWritten
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        ownDeviceID = try c.decodeIfPresent(DeviceID.self, forKey: .ownDeviceID)
        accountFingerprint = try c.decodeIfPresent(String.self, forKey: .accountFingerprint)
        bootstrappedFingerprint = try c.decodeIfPresent(String.self, forKey: .bootstrappedFingerprint)
        syncStatus = try c.decodeIfPresent(SyncStatus.self, forKey: .syncStatus)
        lastFetchAt = try c.decodeIfPresent(Date.self, forKey: .lastFetchAt)
        lastFetchOutcome = try c.decodeIfPresent(FetchOutcome.self, forKey: .lastFetchOutcome)
        devices = try c.decodeIfPresent([DeviceBattery].self, forKey: .devices) ?? []
        lastWritten = try c.decodeIfPresent([DeviceID: DeviceBattery].self, forKey: .lastWritten) ?? [:]
    }

    /// Merges fetched records into `devices` (SYNC-002 R14, ADR-0009 rule 4).
    ///
    /// Per ID the entry with the newer `updatedAt` wins; on a tie the fetched one wins
    /// (it carries `serverModifiedAt`). If `isFullFetch`, entries the fetch did not
    /// return are dropped unless their ID is in `ownIDs`.
    ///
    /// `ownIDs` are this device's records: their local copy always wins over a fetched one,
    /// even on a tie. Only this device writes them, so the hub's copy is at best the same
    /// reading echoed back (stamped with the hub's clock) and at worst an older one; the
    /// fetched copy is taken only when there is no local copy yet.
    public mutating func merge(fetched: [DeviceBattery], isFullFetch: Bool, ownIDs: Set<DeviceID>) {
        var byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        var fetchedIDs = Set<DeviceID>()
        for new in fetched {
            fetchedIDs.insert(new.id)
            if let old = byID[new.id] {
                if ownIDs.contains(new.id) || old.updatedAt > new.updatedAt { continue }
            }
            byID[new.id] = new
        }
        if isFullFetch {
            byID = byID.filter { fetchedIDs.contains($0.key) || ownIDs.contains($0.key) }
        }
        devices = Self.sorted(Array(byID.values))
    }

    /// Sort order of `devices`: kind (in `DeviceKind.allCases` order), then name, then record name.
    public static func sorted(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        let rank = Dictionary(uniqueKeysWithValues: DeviceKind.allCases.enumerated().map { ($1, $0) })
        return devices.sorted { a, b in
            if a.kind != b.kind { return rank[a.kind, default: 0] < rank[b.kind, default: 0] }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id.recordName < b.id.recordName
            }
        }
    }
}
