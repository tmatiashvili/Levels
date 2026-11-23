import Foundation
import LevelsModel
import LevelsNet
import Network
import Synchronization
import Testing
@testable import LevelsSync

private let phoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!)
private let watchLikeID = DeviceID(UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000D")!)
private let laterID = DeviceID(UUID(uuidString: "EEEEEEEE-0000-0000-0000-00000000000E")!)

/// A locator whose port changes when the "Mac" restarts its listener.
private final class MovableLocator: HubLocator {
    private let port = Mutex<UInt16?>(nil)
    func set(_ p: UInt16?) { port.withLock { $0 = p } }
    func endpoint(forTag tag: String, timeout: Duration) async throws(HubError) -> NWEndpoint {
        guard let p = port.withLock({ $0 }) else { throw .notFound }
        return .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: p)!)
    }
}

/// A settable wall clock, so the phone's reports are not held by the ADR-0008 10 s floor.
private final class Wall: Sendable {
    private let t = Mutex(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))  // whole seconds survive the cache JSON
    var date: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 += s } }
}

private func phoneReading(level: Int, at: Date) -> DeviceBattery {
    DeviceBattery(id: phoneID, name: "My iPhone", kind: .iphone, level: level, isCharging: false, updatedAt: at)
}

/// NET-003 over loopback: the real Mac side (listener, router, `HubCacheBackend`) and the
/// iPhone's `LocalNetworkSyncService` over `NWHubTransport`.
@Suite("NET-003 LocalNetworkSyncService loopback", .serialized)
struct LocalNetworkSyncServiceTests {
    @Test func pairPostFetchAwayAndBack() async throws {
        let mac = HubLoopbackTests.Mac()
        await mac.report(level: 80)
        let port = try await mac.listener.start()

        // The iPhone side, not paired yet.
        let wall = Wall()
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("levels-phone-\(UUID().uuidString)"))
        let outbox = HubOutbox()
        let local = LocalOnlySyncService(cache: cache, widgetReloader: {}, onOwnWrite: { outbox.put($0) },
                                         now: { wall.date })
        let store = InMemoryClientPairingStore()
        let locator = MovableLocator()
        locator.set(port)
        let sync = LocalNetworkSyncService(local: local, outbox: outbox,
                                           transport: NWHubTransport(locator: locator, findTimeout: .seconds(1),
                                                                     readyTimeout: .seconds(1)),
                                           pairing: store, identity: FixedDeviceIdentity(phoneID), cache: cache,
                                           persistsETag: false, now: { wall.date })

        // Not paired: no network call, status recorded (R9, AC7).
        await sync.start()
        #expect(await sync.status == .notPaired)
        _ = await sync.report([phoneReading(level: 50, at: wall.date)], reason: .launch)
        #expect(await sync.refresh(.launch))
        #expect(cache.read()?.syncStatus == .notPaired)
        #expect(mac.cache.read()?.devices.contains { $0.id == phoneID } == false)

        // Pair (NET-002), then the first fetch brings the Mac and sends the held own reading.
        let pairing = try await HubLoopbackTests().pair(mac, port: port)
        try store.save(pairing)
        await sync.didPair()
        #expect(await sync.status == .localOnly)
        let ids = Set(cache.read()?.devices.map(\.id) ?? [])
        #expect(ids.contains(mac.info.hubDeviceID) && ids.contains(phoneID))
        #expect(abs((cache.read()?.lastFetchAt ?? .distantPast).timeIntervalSince(wall.date)) < 0.01)
        #expect(mac.cache.read()?.devices.first { $0.id == phoneID }?.level == 50)
        #expect(outbox.value == nil)

        // Post (R2, R4): a new own reading reaches the Mac.
        wall.advance(120)
        _ = await sync.report([phoneReading(level: 48, at: wall.date)], reason: .userRefresh)
        #expect(mac.cache.read()?.devices.first { $0.id == phoneID }?.level == 48)
        #expect(outbox.value == nil)

        // Fetch merged (R3): a record new on the Mac arrives on the next refresh.
        await mac.local.ingest([DeviceBattery(id: watchLikeID, name: "Watch", kind: .watch, level: 30,
                                              isCharging: false, updatedAt: Date())], replacingAllExcept: nil)
        mac.signal.fire()
        await sync.refresh(.foreground)
        #expect(cache.read()?.devices.contains { $0.id == watchLikeID } == true)

        // The hub disappears: away, with the last contact (R5, AC6); the reading waits.
        let contact = wall.date
        await mac.listener.stop()
        locator.set(nil)
        wall.advance(120)
        _ = await sync.report([phoneReading(level: 40, at: wall.date)], reason: .userRefresh)
        await sync.refresh(.userPull)
        #expect(await sync.status == .awayFromHub(lastContactAt: contact))
        #expect(cache.read()?.syncStatus == .awayFromHub(lastContactAt: contact))
        #expect(cache.read()?.devices.contains { $0.id == mac.info.hubDeviceID } == true)  // rows stay
        #expect(outbox.value?.level == 40)

        // Back home: the outbox is sent, the status clears.
        let newPort = try await mac.listener.start()
        locator.set(newPort)
        wall.advance(10)
        await sync.refresh(.networkReachable)
        #expect(await sync.status == .localOnly)
        #expect(outbox.value == nil)
        #expect(mac.cache.read()?.devices.first { $0.id == phoneID }?.level == 40)
        #expect(abs((cache.read()?.lastFetchAt ?? .distantPast).timeIntervalSince(wall.date)) < 0.01)

        // Live updates (R7): a change on the Mac lands without a refresh call.
        await sync.startLiveUpdates()
        try await Task.sleep(for: .milliseconds(300))
        await mac.local.ingest([DeviceBattery(id: laterID, name: "iPad", kind: .ipad, level: 70,
                                              isCharging: false, updatedAt: Date())], replacingAllExcept: nil)
        mac.signal.fire()
        await waitFor(timeout: .seconds(5)) { cache.read()?.devices.contains { $0.id == laterID } == true }
        await sync.stopLiveUpdates()

        // Forget (NET-002 R9): not paired, Mac records stay.
        await sync.forget()
        #expect(await sync.status == .notPaired)
        #expect(store.current() == nil)
        #expect(cache.read()?.devices.contains { $0.id == mac.info.hubDeviceID } == true)
        await mac.listener.stop()
    }

    @Test func removeAllDataNeedsTheMac() async throws {
        let mac = HubLoopbackTests.Mac()
        await mac.report(level: 70)
        let port = try await mac.listener.start()
        let pairing = try await HubLoopbackTests().pair(mac, port: port)
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("levels-phone-\(UUID().uuidString)"))
        let outbox = HubOutbox()
        let local = LocalOnlySyncService(cache: cache, widgetReloader: {}, onOwnWrite: { outbox.put($0) })
        let locator = MovableLocator()
        locator.set(port)
        let sync = LocalNetworkSyncService(local: local, outbox: outbox,
                                           transport: NWHubTransport(locator: locator, findTimeout: .seconds(1),
                                                                     readyTimeout: .seconds(1)),
                                           pairing: InMemoryClientPairingStore(pairing), identity: FixedDeviceIdentity(phoneID),
                                           cache: cache, persistsETag: false)
        await sync.start()
        _ = await sync.report([phoneReading(level: 60, at: Date())], reason: .launch)
        await sync.refresh(.launch)
        #expect(mac.cache.read()?.devices.contains { $0.id == phoneID } == true)

        // Away: throws, nothing changes (R10, AC9).
        await mac.listener.stop()
        locator.set(nil)
        await #expect(throws: HubError.self) { try await sync.removeAllData() }
        #expect(cache.read()?.devices.isEmpty == false)

        // Home: DELETE first, then the local reset.
        locator.set(try await mac.listener.start())
        try await sync.removeAllData()
        #expect(mac.cache.read()?.devices.contains { $0.id == phoneID } == false)
        #expect(cache.read()?.devices.isEmpty ?? true)
        await mac.listener.stop()
    }
}
