import CoreGraphics
import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

@Suite("UI-004 R6 popover height")
struct PopoverLayoutTests {
    let mac = device(id(1), .mac, "MacBook Pro", level: 76)
    let phone = device(id(2), .iphone, "iPhone", level: 18)
    let pods = [airPod(.left, level: 40), airPod(.right, level: 35), airPod(.case, level: 80)]

    let watch = device(id(3), .watch, "Watch", level: 71)

    func height(_ devices: [DeviceBattery], state: DeviceListStore.State = .loaded,
                reportingOff: Bool = false, stacked: Bool = false) -> CGFloat {
        PopoverLayout.height(rows: rows(devices, this: mac.id).rows, state: state, isReportingOff: reportingOff,
                             isStacked: stacked)
    }

    // Pin the numbers: they were measured on the rendered popover (design-fixes harness).
    @Test func plainRowsAndGroup() {
        #expect(height([mac, phone, watch]) == CGFloat(3 * 42 + 56))
        #expect(height([mac, phone] + pods) == CGFloat(2 * 42 + 66 + 56))
    }

    @Test func bannerAddsItsHeight() {
        #expect(height([mac, phone], state: .syncError("x")) == CGFloat(2 * 42 + 56 + 56))
        #expect(height([mac, phone], state: .noICloud) == CGFloat(2 * 42 + 56 + 56))
        #expect(height([mac, phone], reportingOff: true) == CGFloat(2 * 42 + 56 + 56))
    }

    @Test func onlyThisDeviceAddsFooterNote() {
        #expect(height([mac, phone], state: .onlyThisDevice) == CGFloat(2 * 42 + 28 + 56))
    }

    @Test func emptyKeepsMinimum() {
        #expect(height([], state: .empty) == PopoverLayout.minHeight)
        #expect(height([], state: .loading) == PopoverLayout.minHeight)
    }

    @Test func stackedRowsAreTaller() {
        #expect(height([mac, phone], stacked: true) == CGFloat(2 * 80 + 56))
        #expect(height([mac] + pods, stacked: true) == CGFloat(80 + 104 + 56))
    }

    @Test func emptyAndSingleRowKeepMinimum() {
        #expect(height([mac], state: .onlyThisDevice) == PopoverLayout.minHeight)
    }

    @Test func capsAt480() {
        let many = (10..<30).map { device(id($0), .iphone, "Phone \($0)", level: 50) }
        #expect(height(many) == CGFloat(480))
    }
}
