import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

/// NET-004 R4, R11 (AC1, AC3): hub statuses in the store.
@MainActor
@Suite("NET-004 store state in hub mode")
struct HubStateTests {
    let me = device(id(1), .iphone, "iPhone", level: 62)
    let mac = device(id(2), .mac, "Mac", level: 80)

    func state(_ status: SyncStatus?, hub: Bool = true) -> DeviceListStore.State {
        let file = SnapshotFile(ownDeviceID: me.id, syncStatus: status, devices: [me, mac])
        let rows = DeviceRows(devices: file.devices, thisDeviceID: me.id, preferences: DisplayPreferences(), now: Date()).rows
        return DeviceListStore.state(snapshot: file, rows: rows, error: nil, dismissed: nil, isHubMode: hub)
    }

    @Test func mapsEveryHubStatus() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(state(.notPaired) == .notPaired)
        #expect(state(.awayFromHub(lastContactAt: at)) == .hub(.away(lastContactAt: at)))
        #expect(state(.restricted) == .hub(.localNetworkOff))
        #expect(state(.misconfigured(code: 401)) == .hub(.forgotThisPhone))
        #expect(state(.misconfigured(code: 426)) == .hub(.updateNeeded))
        #expect(state(.localOnly) == .loaded)
    }

    @Test func noICloudBannerInHubMode() {
        #expect(state(.restricted) != .noICloud)
        #expect(state(.restricted, hub: false) == .noICloud)
    }

    @Test func bannerVisibility() {
        #expect(SyncStatusBanner.isVisible(state: .hub(.away(lastContactAt: nil)), isReportingOff: false))
        #expect(!SyncStatusBanner.isVisible(state: .notPaired, isReportingOff: false))
    }
}
