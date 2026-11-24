import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import Testing
@testable import LevelsSync

private let uMac = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000D1")!)
private let uPhone = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000D2")!)
private let uHub = UUID(uuidString: "C0FFEE00-0000-4000-8000-0000000000D3")!

/// This iPhone's battery as the app's `UIDevice` read would give it, settable by the test.
private final class PhoneBattery: Sendable {
    private let level = Mutex<Int?>(60)
    let date: DateBox
    init(date: DateBox) { self.date = date }
    func set(_ l: Int?) { level.withLock { $0 = l } }
    func record() -> DeviceBattery? {
        DeviceBattery(id: uPhone, name: "iPhone", kind: .iphone, level: level.withLock { $0 }, isCharging: false,
                      isPluggedIn: false, isLowPowerMode: false, updatedAt: date.value)
    }
}

/// Every path where the iPhone talks to the Mac sends a changed or 5-minute-old own reading
/// first. The bug: the Mac kept 60 % from 14:52 while the iPhone fetched again later.
@Suite("iPhone sends its own reading on every path to the Mac")
struct OwnReadingUploadTests {
    let hub = ScriptedHub()
    let date = DateBox()
    let reporting = ReportingSetting.inMemory()
    let uploaded = UploadedReadingMemory.inMemory()

    private func service(battery: PhoneBattery?) -> (LocalNetworkSyncService, HubOutbox) {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("levels-own-\(UUID().uuidString)"))
        let outbox = HubOutbox()
        let date = date
        let local = LocalOnlySyncService(cache: cache, reporting: reporting, widgetReloader: {},
                                         onOwnWrite: { outbox.put($0) }, now: { date.value })
        let pairing = InMemoryClientPairingStore(HubPairing(hubID: uHub, hubTag: "c0ff", hubDeviceID: uMac, hubName: "Mac",
                                                            key: Data(repeating: 7, count: 32), pairedAt: Date()))
        var own: (@Sendable () async -> DeviceBattery?)?
        if let battery { own = { @Sendable in battery.record() } }
        let sync = LocalNetworkSyncService(local: local, outbox: outbox, transport: hub, pairing: pairing,
                                           identity: FixedDeviceIdentity(uPhone), cache: cache, persistsETag: false,
                                           now: { date.value }, uploaded: uploaded, ownRecord: own)
        return (sync, outbox)
    }

    private var routes: [String] { hub.requests.map { "\($0.method) \($0.path)" } }
    private var posted: [Int?] {
        hub.requests.filter { $0.path == HubProtocol.Path.readings }
            .compactMap { try? HubWire.decoder().decode([DeviceBattery].self, from: $0.body).first?.level }
    }

    private func reading(_ level: Int) -> DeviceBattery {
        DeviceBattery(id: uPhone, name: "iPhone", kind: .iphone, level: level, isCharging: false, isPluggedIn: false,
                      isLowPowerMode: false, updatedAt: date.value)
    }

    @Test func refreshWithoutAReportSendsTheFreshReadingFirst() async {
        // Wi-Fi back, launch race, or any refresh no report went before.
        let (sync, _) = service(battery: PhoneBattery(date: date))
        await sync.refresh(.networkReachable)
        #expect(routes == ["POST /v1/readings", "GET /v1/snapshot"])
        #expect(posted == [60])
    }

    @Test func refreshSendsAgainOnlyWhenChangedOrFiveMinutesOld() async {
        let battery = PhoneBattery(date: date)
        let (sync, _) = service(battery: battery)
        await sync.refresh(.foreground)
        date.advance(60)
        await sync.refresh(.foreground)  // same level, 1 min later: GET only
        #expect(posted == [60])
        battery.set(59)
        date.advance(1)
        await sync.refresh(.foreground)  // changed: sent at once
        date.advance(300)
        await sync.refresh(.backgroundRefresh)  // unchanged, 5 min on: sent again
        #expect(posted == [60, 59, 59])
    }

    @Test func unknownLevelIsNeverSent() async {
        let battery = PhoneBattery(date: date)
        battery.set(nil)  // UIDevice −1: monitoring not on yet
        let (sync, _) = service(battery: battery)
        await sync.refresh(.launch)
        #expect(routes == ["GET /v1/snapshot"])
    }

    @Test func aHeldCacheWriteStillReachesTheMac() async {
        // The cache holds a level change for 60 s; the Mac used to wait for the next contact.
        let (sync, outbox) = service(battery: nil)
        _ = await sync.report([reading(60)], reason: .launch)
        date.advance(20)
        let outcome = await sync.report([reading(59)], reason: .batteryChange)
        #expect(outcome != .uploaded)  // the cache write is held
        #expect(posted == [60, 59])
        #expect(outbox.value == nil)
    }

    @Test func anUnchangedReportIsNotResentWithinFiveMinutes() async {
        let (sync, _) = service(battery: nil)
        _ = await sync.report([reading(60)], reason: .launch)
        date.advance(30)
        _ = await sync.report([reading(60)], reason: .foreground)
        #expect(posted == [60])
        date.advance(300)
        _ = await sync.report([reading(60)], reason: .backgroundRefresh)
        #expect(posted == [60, 60])
    }

    @Test func aQueuedCopyOfWhatTheMacHasIsDropped() async {
        // A held cache write lands later and puts the already-sent reading in the outbox.
        let (sync, outbox) = service(battery: nil)
        let r = reading(60)
        _ = await sync.report([r], reason: .launch)
        outbox.put(r)
        await sync.refresh(.foreground)
        #expect(posted == [60])
        #expect(outbox.value == nil)
    }

    @Test func reportingOffSendsNothing() async {
        reporting.setEnabled(false)
        let (sync, _) = service(battery: PhoneBattery(date: date))
        _ = await sync.report([reading(60)], reason: .launch)
        await sync.refresh(.foreground)
        #expect(posted.isEmpty)
    }

    @Test func liveUpdatesSendTheReading() async {
        let battery = PhoneBattery(date: date)
        let (sync, _) = service(battery: battery)
        await sync.startLiveUpdates()
        await waitFor { posted == [60] }
        battery.set(58)
        date.advance(1)
        await waitFor { posted == [60, 58] }
        await sync.stopLiveUpdates()
    }

    @Test func aNewPairingForgetsWhatWasSent() async {
        let (sync, _) = service(battery: PhoneBattery(date: date))
        await sync.refresh(.foreground)
        await sync.didPair()  // the new Mac has nothing from us
        #expect(posted == [60, 60])
    }
}
