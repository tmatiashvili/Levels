import CryptoKit
import Foundation
import LevelsModel
import Synchronization
@testable import LevelsNet

let hubID = UUID(uuidString: "AB12CDEF-0000-4000-8000-000000000001")!
let macID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
let phoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
let otherPhoneID = DeviceID(UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func macRecord(level: Int = 80, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: macID, name: "Office Mac", kind: .mac, level: level, isCharging: false, isPluggedIn: false, updatedAt: at)
}

func phoneRecord(_ id: DeviceID = phoneID, level: Int = 55, kind: DeviceKind = .iphone, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: id, name: "My iPhone", kind: kind, level: level, isCharging: true, updatedAt: at)
}

func airpodRecord(level: Int = 40, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: .accessory(key: "AA:BB:CC:DD:EE:FF", component: .left), name: "AirPods", kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: macID, kind: .airpods, groupID: UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000004")!, component: .left),
                  level: level, isCharging: false, updatedAt: at)
}

let hubInfo = HubInfo(hubID: hubID, hubDeviceID: macID, hubName: "Office Mac")

/// A seeded generator (SplitMix64) for repeatable codes.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A ``HubBackend`` over an in-memory device list.
final class FakeBackend: HubBackend {
    struct State {
        var devices: [DeviceBattery] = []
        var reporting = true
        var ingested: [DeviceBattery] = []
        var removed: [DeviceID] = []
        var forgotten: [DeviceID] = []
        var seen: [DeviceID] = []
        var paired: Set<DeviceID> = []
        var pushTokens: [DeviceID: [PushToken]] = [:]
    }
    let state = Mutex(State())
    let signal = HubChangeSignal()
    let window: PairingWindow?

    init(devices: [DeviceBattery] = [], paired: Set<DeviceID> = [phoneID], window: PairingWindow? = nil) {
        self.window = window
        state.withLock {
            $0.devices = devices
            $0.paired = paired
        }
    }

    func setDevices(_ devices: [DeviceBattery]) {
        state.withLock { $0.devices = devices }
        signal.fire()
    }

    func snapshot() async -> HubSnapshot? {
        let s = state.withLock { $0 }
        guard s.reporting else { return nil }
        return HubSnapshot(hubID: hubID, hubDeviceID: macID, generatedAt: t0, devices: s.devices)
    }

    func changes() -> AsyncStream<Void> { signal.stream() }

    func ingest(_ record: DeviceBattery) async -> Bool {
        state.withLock { s in
            s.ingested.append(record)
            s.devices.removeAll { $0.id == record.id }
            s.devices.append(record)
        }
        return true
    }

    func setPushTokens(_ tokens: [PushToken], for id: DeviceID) async -> Bool {
        state.withLock { s in
            guard s.paired.contains(id) else { return false }
            s.pushTokens[id] = tokens
            return true
        }
    }

    func removeRecord(_ id: DeviceID) async { state.withLock { $0.removed.append(id) } }
    func forget(_ id: DeviceID) async { state.withLock { $0.forgotten.append(id); $0.paired.remove(id) } }
    func isPaired(_ id: DeviceID) -> Bool { state.withLock { $0.paired.contains(id) } }

    func pair(_ request: PairRequest) async throws(PairError) -> PairResponse {
        guard let window else { throw .refused }
        return try window.accept(request)
    }

    func confirmPairing(_ request: PairConfirmRequest) async throws(PairError) {
        guard let window else { throw .refused }
        try window.reveal(request)
        switch await window.decision() {
        case .matched: return
        case .cancelled: throw .refused
        case .expired: throw .timedOut
        }
    }

    func seen(_ id: DeviceID) async {
        state.withLock { $0.seen.append(id) }
        _ = window?.confirm(id)
    }
}

func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }

func hexData(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
