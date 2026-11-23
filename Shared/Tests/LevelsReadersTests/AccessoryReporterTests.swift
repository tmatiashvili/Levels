import Foundation
import LevelsModel
import Testing
@testable import LevelsReaders

@Suite("MAC-003 AccessoryReporter")
struct AccessoryReporterTests {
    let clock = ManualClock()
    let sync = FakeSync()
    let mac = DeviceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    func airPods(_ left: Int, _ right: Int, _ casePct: Int) -> AccessoryScan {
        let parts: [(AccessoryComponent, Int)] = [(.left, left), (.right, right), (.case, casePct)]
        return AccessoryScan(readings: parts.map {
            AccessoryReading(key: "00:11:22:33:44:04", name: "TPods", kind: .airpods, component: $0.0, level: $0.1, readAt: clock.date)
        }, headphonesConnected: true)
    }

    var mouse: AccessoryScan {
        AccessoryScan(readings: [AccessoryReading(key: "00:11:22:33:44:20", name: "Magic Mouse", kind: .mouse,
                                                  component: .main, level: 64, readAt: clock.date)])
    }

    func reporter(_ reader: FixedAccessoryReader, parent: DeviceID?? = nil) -> AccessoryReporter {
        let id = parent ?? mac
        return AccessoryReporter(reader: reader, sync: sync, parentID: { id }, clock: clock)
    }

    @Test func R3_R3a_launchReportsEveryComponentWithParentThisMac() async {
        let r = reporter(FixedAccessoryReader(airPods(40, 35, 80)))
        await r.start()
        await waitFor { [sync] in await sync.calls.count == 1 }
        let call = await sync.calls[0]
        #expect(call.reason == .launch)
        #expect(call.devices.count == 3)
        #expect(call.devices.allSatisfy { $0.kind == .accessory && $0.accessory?.parentDeviceID == self.mac })
        #expect(Set(call.devices.compactMap { $0.accessory?.groupID }).count == 1)
        #expect(Set(call.devices.map(\.id)) == Set([AccessoryComponent.left, .right, .case].map {
            DeviceID.accessory(key: "00:11:22:33:44:04", component: $0)
        }))
        await r.stop()
    }

    @Test func R4_disconnectWritesNothing() async {
        let reader = FixedAccessoryReader(mouse)
        let r = reporter(reader)
        await r.start()
        await waitFor { [sync] in await sync.calls.count == 1 }
        reader.emit(.empty)  // IOKit termination: the mouse is gone
        await waitFor { reader.readCount == 2 }
        await settle()
        #expect(await sync.calls.count == 1)  // the record keeps its last level and updatedAt
        #expect(await r.connected.isEmpty)
        await r.stop()
    }

    @Test func R1_connectEventReportsNow() async {
        let reader = FixedAccessoryReader(.empty)
        let r = reporter(reader)
        await r.start()
        await waitFor { reader.readCount == 1 }
        #expect(await sync.calls.isEmpty)  // nothing connected: nothing sent
        reader.emit(mouse)
        await waitFor { [sync] in await sync.calls.count == 1 }
        #expect(await sync.calls[0].reason == .batteryChange)
        #expect(await sync.calls[0].devices.first?.accessory?.kind == .mouse)
        await r.stop()
    }

    @Test func ADR0014_pollIs5MinWhileConnectedAnd15OtherwiseWithTolerance() async {
        let reader = FixedAccessoryReader(airPods(40, 35, 80))
        let r = reporter(reader)
        await r.start()
        await waitFor { [clock] in clock.sleeperCount == 1 }
        #expect(await r.currentInterval == .seconds(300))
        #expect(clock.requests.last?.tolerance == .seconds(60))

        reader.set(.empty)
        clock.advance(by: .seconds(300))
        await waitFor { reader.readCount == 2 }
        await waitFor { [clock] in clock.sleeperCount == 1 }
        #expect(await r.currentInterval == .seconds(900))
        #expect(clock.requests.last?.duration == .seconds(900))

        reader.set(mouse)  // HID accessory connected: 5 min again (R1)
        clock.advance(by: .seconds(900))
        await waitFor { [sync] in await sync.calls.count == 2 }
        #expect(await sync.calls[1].reason == .heartbeat)
        await waitFor { [clock] in clock.sleeperCount == 1 }
        #expect(await r.currentInterval == .seconds(300))
        await r.stop()
        #expect(clock.sleeperCount == 0)
    }

    @Test func ADR0014_headphonesWithoutLevelsStillPollEvery5Min() {
        #expect(AccessoryReporter.interval(after: AccessoryScan(headphonesConnected: true)) == .seconds(300))
        #expect(AccessoryReporter.interval(after: .empty) == .seconds(900))
    }

    @Test func ADR0014_onlyOnePollPendingAfterEvents() async {
        let reader = FixedAccessoryReader(mouse)
        let r = reporter(reader)
        await r.start()
        await waitFor { [clock] in clock.sleeperCount == 1 }
        reader.emit(mouse)
        reader.emit(mouse)
        await waitFor { reader.readCount == 3 }
        await settle()
        #expect(clock.sleeperCount == 1)
        await r.stop()
    }

    @Test func R5_eachProblemIsLoggedOncePerRun() async {
        let reader = FixedAccessoryReader(AccessoryScan(problems: ["a", "b"]))
        let r = reporter(reader)
        await r.report(reason: .wake)
        await r.report(reason: .wake)
        reader.set(AccessoryScan(problems: ["b", "c"]))
        await r.report(reason: .wake)
        #expect(await r.loggedProblems == ["a", "b", "c"])
        #expect(await sync.calls.isEmpty)
    }

    @Test func noDeviceIDSkipsTheReport() async {
        let r = reporter(FixedAccessoryReader(mouse), parent: .some(nil))
        #expect(await r.report(reason: .wake) == nil)
        #expect(await sync.calls.isEmpty)
    }

    @Test func explicitReasonsPassThrough() async {
        let r = reporter(FixedAccessoryReader(mouse))
        #expect(await r.report(reason: .wake) == .uploaded)
        #expect(await r.report(reason: .chargerChange) == .uploaded)
        #expect(await sync.reasons == [.wake, .chargerChange])
    }

    @Test func stopEndsEventsAndPoll() async {
        let reader = FixedAccessoryReader(mouse)
        let r = reporter(reader)
        await r.start()
        await waitFor { [clock] in clock.sleeperCount == 1 }
        await r.stop()
        #expect(clock.sleeperCount == 0)
        reader.emit(mouse)
        await settle()
        #expect(await sync.calls.count == 1)
    }
}
