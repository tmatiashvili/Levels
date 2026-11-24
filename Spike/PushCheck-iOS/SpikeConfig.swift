// SPIKE-001 throwaway code. Not kept after the spike.

import Foundation

enum SpikeConfig {
    /// EDIT ME: replace <rdns> with your reverse-DNS prefix, for example "com.example".
    /// Must match the container in PushCheck.entitlements.
    static let containerID = "iCloud.<rdns>.levels"

    /// Fixed names from ADR-0005 and ADR-0006 / SYNC-001 R3.
    static let zoneName = "Levels"
    static let subscriptionID = "levels-private-db"
}
