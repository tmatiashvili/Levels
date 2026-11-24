// SPIKE-001 throwaway code. Not kept after the spike.

import Foundation

enum SpikeConfig {
    /// EDIT ME: replace <rdns> with your reverse-DNS prefix, for example "com.example".
    /// Must match the container in PushCheckMac.entitlements.
    static let containerID = "iCloud.<rdns>.levels"

    /// Fixed names from ADR-0005.
    static let zoneName = "Levels"
    static let recordType = "DeviceBattery"

    /// Fixed record name for the one test record, a lowercase UUID (ADR-0005).
    /// Not the Mac's real device ID, so it never collides with a real Levels record.
    static let testRecordName = "5a1e7e57-0001-4001-8001-5b1ce0000001"
}
