import CryptoKit
import Foundation
import LevelsModel
import LevelsNet
import Network
import Synchronization
import Testing
@testable import LevelsSync

private let hubMacID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!)
private let hubPhoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!)
private let strangerID = DeviceID(UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000C")!)
private let hubUUID = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!

private func macReading(level: Int = 80, at: Date) -> DeviceBattery {
    DeviceBattery(id: hubMacID, name: "Office Mac", kind: .mac, level: level, isCharging: false, isPluggedIn: false, updatedAt: at)
}

private func phoneReading(level: Int = 55, at: Date) -> DeviceBattery {
    DeviceBattery(id: hubPhoneID, name: "My iPhone", kind: .iphone, level: level, isCharging: true, updatedAt: at)
}

private func otherReading(_ id: DeviceID, at: Date) -> DeviceBattery {
    DeviceBattery(id: id, name: "Old iPad", kind: .ipad, level: 10, isCharging: false, updatedAt: at)
}

private func tempCache() -> SnapshotCache {
    SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("levels-hub-\(UUID().uuidString)"))
}

@Suite("NET-001 LocalOnlySyncService.ingest (R10, AC7–AC9)")
struct IngestTests {
    let clock = ManualClock()
    let reloads = ReloadCounter()
    let cache = tempCache()

    func service(reporting: ReportingSetting = .inMemory()) -> LocalOnlySyncService {
        let clock = clock, reloads = reloads
        return LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: { reloads.hit() },
                                    now: { clock.date }, clock: clock)
    }

    @Test func AC7_olderReadingKeepsCacheAndDoesNotReload() async {
        let s = service()
        let t = clock.date
        #expect(await s.ingest([phoneReading(level: 50, at: t)], replacingAllExcept: nil))
        #expect(reloads.value == 1)
        clock.advance(by: .seconds(120))
        #expect(await s.ingest([phoneReading(level: 40, at: t - 60)], replacingAllExcept: nil) == false)
        #expect(cache.read()?.devices.first?.level == 50)
        #expect(reloads.value == 1)
        #expect(await s.ingest([phoneReading(level: 45, at: t + 60)], replacingAllExcept: nil))
        #expect(cache.read()?.devices.first?.level == 45)
        #expect(reloads.value == 2)
    }

    @Test func AC7_tieGoesToTheIncomingRecord() async {
        let s = service()
        let t = clock.date
        await s.ingest([phoneReading(level: 50, at: t)], replacingAllExcept: nil)
        await s.ingest([phoneReading(level: 51, at: t)], replacingAllExcept: nil)
        #expect(cache.read()?.devices.first?.level == 51)
    }

    @Test func AC8_fullFormDropsMissingButKeepsOwn() async {
        let s = service()
        let t = clock.date
        _ = await s.report([phoneReading(at: t)], reason: .launch)  // own record
        await s.ingest([macReading(at: t), otherReading(strangerID, at: t)], replacingAllExcept: nil)
        #expect(cache.read()?.devices.count == 3)
        await s.ingest([macReading(level: 70, at: t + 1)], replacingAllExcept: [hubPhoneID])
        let ids = Set(cache.read()?.devices.map(\.id) ?? [])
        #expect(ids == [hubMacID, hubPhoneID])
        #expect(cache.read()?.ownDeviceID == hubPhoneID)
    }

    @Test func AC9_reportingOffWritesNothing() async {
        let reporting = ReportingSetting.inMemory(enabled: false)
        let s = service(reporting: reporting)
        #expect(await s.ingest([phoneReading(at: clock.date)], replacingAllExcept: nil) == false)
        #expect(cache.read() == nil)
    }

    @Test func removeLocalDropsOneRecord() async {
        let s = service()
        let t = clock.date
        await s.ingest([macReading(at: t), phoneReading(at: t)], replacingAllExcept: nil)
        await s.removeLocal(hubPhoneID)
        #expect(cache.read()?.devices.map(\.id) == [hubMacID])
    }
}

/// The NET-001 / NET-002 flow end to end on loopback: real listener, router, backend,
/// cache and sync service on the "Mac" side; `PairingClient` and `HubClient` over
/// `NWHubTransport` on the "iPhone" side.
@Suite("NET-001/002 loopback end to end", .serialized)
struct HubLoopbackTests {
    final class Mac: Sendable {
        let cache = tempCache()
        let reporting = ReportingSetting.inMemory()
        let store = InMemoryHubPairingStore()
        let window: PairingWindow
        let local: LocalOnlySyncService
        let backend: HubCacheBackend
        let listener: HubListener
        let signal = HubChangeSignal()
        let info = HubInfo(hubID: hubUUID, hubDeviceID: hubMacID, hubName: "Office Mac")

        init() {
            window = PairingWindow(store: store)
            local = LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: {})
            backend = HubCacheBackend(local: local, cache: cache, reporting: reporting, store: store, window: window,
                                      signal: signal, hub: { [info] in info })
            listener = HubListener(router: HubRouter(backend: backend), keyring: HubKeyring(store: store, window: window),
                                   loopbackOnly: true)
            backend.attach(listener)
            let listener = listener
            window.setObserver { Task { await listener.reload() } }
        }

        /// A Mac report, as `MacAppModel` does it: write, then fire the change relay.
        func report(level: Int) async {
            _ = await local.report([macReading(level: level, at: Date())], reason: .userRefresh)
            signal.fire()
        }
    }

    func pair(_ mac: Mac, port: UInt16, id: DeviceID = hubPhoneID) async throws(PairError) -> HubPairing {
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        return try await pair(mac, port: port, code: code, id: id)
    }

    /// The iPhone's side with an existing code; the "owner" taps They match on the Mac once
    /// it shows the same number as the iPhone, and on the iPhone (NET-002 R6a, R6b; call 30).
    func pair(_ mac: Mac, port: UInt16, code: String, id: DeviceID = hubPhoneID, name: String = "My iPhone") async throws(PairError) -> HubPairing {
        let session = try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag,
                                                      code: code, me: PairRequestIdentity(deviceID: id, name: name, kind: .iphone))
        await waitFor {
            if case .confirming(_, let shown, _) = mac.window.state { return shown == session.confirmationCode }
            return false
        }
        #expect(mac.window.approve())
        session.confirmLocally()
        return try await session.finish()
    }

    @Test func fullFlow() async throws {
        let mac = Mac()
        await mac.report(level: 80)
        let port = try await mac.listener.start()

        // Pair (NET-002 R4–R7).
        let pairing = try await pair(mac, port: port)
        #expect(pairing.hubID == hubUUID && pairing.hubDeviceID == hubMacID && pairing.hubName == "Office Mac")
        #expect(mac.store.key(for: hubPhoneID).map { $0.withUnsafeBytes { Data($0) } } == pairing.key)
        #expect(mac.window.state == .paired(name: "My iPhone"))
        #expect(await mac.listener.port == port)  // rebuilt on the same port

        let phoneStore = InMemoryClientPairingStore(pairing)
        let transport = NWHubTransport(locator: FixedHubLocator(loopbackPort: port))
        let client = HubClient(transport: transport, pairing: phoneStore, me: hubPhoneID)

        // Fetch, then 304 on the same ETag (R4).
        guard case .changed(let first, let tag) = try await client.snapshot(ifNoneMatch: nil) else {
            Issue.record("expected 200"); return
        }
        #expect(first.devices.map(\.id) == [hubMacID] && first.devices.first?.level == 80)
        #expect(try await client.snapshot(ifNoneMatch: tag) == .notModified(etag: tag))

        // Long-poll wakes on a change (R11).
        let poll = Task { try await client.snapshot(ifNoneMatch: tag, wait: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        // (A second Mac report would be held by ADR-0008's 10 s floor; another device's record
        // arriving changes the cache at once.)
        await mac.local.ingest([otherReading(strangerID, at: Date())], replacingAllExcept: nil)
        mac.signal.fire()
        let woke = try await poll.value
        #expect(ContinuousClock.now - started < .seconds(5))
        guard case .changed(let second, let tag2) = woke else { Issue.record("long-poll did not wake"); return }
        #expect(second.devices.map(\.id).contains(strangerID) && tag2 != tag)

        // POST the iPhone's reading; it appears in the Mac cache with the Mac's receive time (R9).
        let before = Date()
        let reading = phoneReading(level: 42, at: Date().addingTimeInterval(3600))  // clock ahead
        _ = try await client.post(reading)
        let cached = try #require(mac.cache.read()?.devices.first { $0.id == hubPhoneID })
        #expect(cached.level == 42)
        #expect(cached.serverModifiedAt.map { $0 >= before && $0 <= Date() } == true)

        // Wrong key rejected (R5).
        var bad = pairing
        bad.key = Data(repeating: 0xEE, count: 32)
        let badClient = HubClient(transport: NWHubTransport(locator: FixedHubLocator(loopbackPort: port)),
                                  pairing: InMemoryClientPairingStore(bad), me: hubPhoneID)
        await #expect(throws: HubError.handshakeRefused) { try await badClient.snapshot(ifNoneMatch: nil) }

        // DELETE /v1/devices/me removes the record (NET-003 R10).
        try await client.deleteMe()
        #expect(mac.cache.read()?.devices.contains { $0.id == hubPhoneID } == false)

        // Removed on the Mac (NET-002 R9, AC7): the next handshake fails.
        try mac.store.remove(hubPhoneID)
        await mac.listener.reload()
        await mac.listener.closeConnections(of: hubPhoneID)
        await transport.reset()
        await #expect(throws: HubError.handshakeRefused) { try await client.snapshot(ifNoneMatch: nil) }

        await mac.listener.stop()
    }

    /// A POST while the long-poll holds the kept connection used to replace it and leave the
    /// old one open; a few rounds filled the Mac's 4-connection limit (R12) and the iPhone
    /// went "away". Now the POST gets a short connection that is closed afterwards.
    @Test func postDuringLongPollDoesNotLeakConnections() async throws {
        let mac = Mac()
        await mac.report(level: 80)
        let port = try await mac.listener.start()
        let pairing = try await pair(mac, port: port)
        let transport = NWHubTransport(locator: FixedHubLocator(loopbackPort: port))
        let client = HubClient(transport: transport, pairing: InMemoryClientPairingStore(pairing), me: hubPhoneID)
        guard case .changed(_, var tag) = try await client.snapshot(ifNoneMatch: nil) else {
            Issue.record("expected 200"); return
        }
        for round in 0..<6 {
            let current = tag
            let poll = Task { try await client.snapshot(ifNoneMatch: current, wait: .seconds(20)) }
            try await Task.sleep(for: .milliseconds(300))
            _ = try await client.post(phoneReading(level: 40 + round, at: Date()))  // wakes the poll
            guard case .changed(_, let next) = try await poll.value else { Issue.record("poll did not wake"); return }
            tag = next
        }
        try await Task.sleep(for: .milliseconds(300))  // let the server see the closes
        #expect(await mac.listener.connectionCount <= 1)
        await transport.reset()
        await mac.listener.stop()
    }

    @Test func wrongCodeThenForget() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let wrong = code == "111111" ? "222222" : "111111"
        await #expect(throws: PairError.wrongCode) {
            try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag, code: wrong,
                                            me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone))
        }
        await waitFor {
            if case .open(_, _, 1) = mac.window.state { return true }
            return false
        }
        #expect(mac.store.all().isEmpty)

        let pairing = try await pair(mac, port: port, code: code)
        let phoneStore = InMemoryClientPairingStore(pairing)
        let client = HubClient(transport: NWHubTransport(locator: FixedHubLocator(loopbackPort: port)), pairing: phoneStore, me: hubPhoneID)
        #expect(await client.forget())  // DELETE /v1/pairing
        #expect(phoneStore.current() == nil)
        #expect(mac.store.all().isEmpty)
        await mac.listener.stop()
    }

    @Test func secondPairingAfterSuccessIsRefused() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        _ = try await pair(mac, port: port, code: code)
        // Single use: the same code no longer handshakes (NET-002 R2, edge "two iPhones").
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: PairError.wrongCode) {
            try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag, code: code,
                                            me: PairRequestIdentity(deviceID: strangerID, name: "Other", kind: .iphone))
        }
        await mac.listener.stop()
    }

    /// Call 30: the numbers differ (or the owner is unsure) and the owner taps Cancel.
    /// The iPhone gets `.refused`, nothing is stored, and the code is spent.
    @Test func cancelOnTheMacRefusesThePairing() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let shown = Mutex<String?>(nil)
        let attempt = Task { () async -> Result<HubPairing, PairError> in
            do throws(PairError) {
                return .success(try await PairingClient().pair(
                    with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag, code: code,
                    me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone),
                    confirm: { c in
                        shown.withLock { $0 = c }
                        try? await Task.sleep(for: .seconds(30))  // the iPhone owner hasn't answered
                        return true
                    }))
            } catch { return .failure(error) }
        }
        await waitFor {
            if case .confirming(_, let sas, _) = mac.window.state { return sas == shown.withLock({ $0 }) }
            return false
        }
        mac.window.close()  // the sheet's Cancel
        #expect(await attempt.value.failure == .refused)
        #expect(mac.store.all().isEmpty)
        #expect(mac.window.codeKey == nil && mac.window.state == .closed)
        await mac.listener.stop()
    }

    /// Call 30: the iPhone gives up (Cancel on the iPhone) while the Mac shows the number.
    @Test func cancelOnTheIPhoneStopsWaiting() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let session = try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag,
                                                      code: code, me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone))
        let finishing = Task { () async -> Result<HubPairing, PairError> in
            do throws(PairError) { return .success(try await session.finish()) } catch { return .failure(error) }
        }
        await waitFor {
            if case .confirming = mac.window.state { return true }
            return false
        }
        session.cancel()
        #expect(await finishing.value.failure != nil)
        #expect(mac.store.all().isEmpty)
        await mac.listener.stop()
    }

    /// R6b: the Mac's 204 alone is not enough; nothing is returned (so nothing can be saved)
    /// and the new key is not used until the iPhone's owner taps They match too.
    @Test func R6b_macApprovalAloneDoesNotPair() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let session = try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag,
                                                      code: code, me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone))
        let done = Mutex(false)
        let finishing = Task { () async -> Result<HubPairing, PairError> in
            defer { done.withLock { $0 = true } }
            do throws(PairError) { return .success(try await session.finish()) } catch { return .failure(error) }
        }
        await waitFor {
            if case .confirming = mac.window.state { return true }
            return false
        }
        #expect(mac.window.approve())
        try await Task.sleep(for: .milliseconds(500))
        #expect(!done.withLock { $0 })        // still waiting for the iPhone's tap
        #expect(mac.store.all().isEmpty)        // R7 (first request with the new key) not sent
        session.confirmLocally()
        let pairing = try await finishing.value.get()
        #expect(mac.store.key(for: hubPhoneID).map { $0.withUnsafeBytes { Data($0) } } == pairing.key)
        await mac.listener.stop()
    }

    /// R6b: Cancel on the iPhone after the Mac's 204 still refuses; the Mac never gets R7.
    @Test func R6b_cancelOnTheIPhoneAfterMacApprovalSavesNothing() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let session = try await PairingClient().start(with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag,
                                                      code: code, me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone))
        let finishing = Task { () async -> Result<HubPairing, PairError> in
            do throws(PairError) { return .success(try await session.finish()) } catch { return .failure(error) }
        }
        await waitFor {
            if case .confirming = mac.window.state { return true }
            return false
        }
        #expect(mac.window.approve())
        try await Task.sleep(for: .milliseconds(300))
        session.cancel()
        #expect(await finishing.value.failure == .refused)
        try await Task.sleep(for: .milliseconds(200))
        #expect(mac.store.all().isEmpty)
        await mac.listener.stop()
    }

    /// R6b: the iPhone's They match first, then the Mac's: either order pairs.
    @Test func R6b_iPhoneFirstThenMacPairs() async throws {
        let mac = Mac()
        await mac.report(level: 60)
        let port = try await mac.listener.start()
        let code = mac.window.open(hub: mac.info)
        await mac.listener.reload()
        let pairing = try await PairingClient().pair(
            with: FixedHubLocator(loopbackPort: port).endpoint, hubTag: mac.info.tag, code: code,
            me: PairRequestIdentity(deviceID: hubPhoneID, name: "My iPhone", kind: .iphone),
            confirm: { _ in
                Task {
                    await waitFor {
                        if case .confirming = mac.window.state { return true }
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    _ = mac.window.approve()
                }
                return true
            })
        #expect(mac.store.key(for: hubPhoneID).map { $0.withUnsafeBytes { Data($0) } } == pairing.key)
        await mac.listener.stop()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
