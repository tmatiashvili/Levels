import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

@Suite("UI-004 MenuBarLabelModel")
struct MenuBarLabelTests {
    let mac = device(id(1), .mac, "MacBook Pro", level: 76)
    let phone = device(id(2), .iphone, "iPhone", level: 18)
    let watch = device(id(3), .watch, "Watch", level: 71)

    func label(_ devices: [DeviceBattery], mode: MenuBarMode = .lowest) -> MenuBarLabelContent {
        MenuBarLabelModel.content(rows: rows(devices, this: mac.id).rows, mode: mode, now: now, locale: en)
    }

    @Test func AC1_lowestOtherDevice() {
        let c = label([mac, phone, watch])
        #expect(c.symbol == "iphone")
        #expect(c.text == "18%")
    }

    @Test func AC2_staleOtherDeviceInParentheses() {
        let c = label([mac, device(id(2), .iphone, "iPhone", level: 40, age: 3 * hour)])
        #expect(c.text == "(40%)")
    }

    @Test func AC3_noOtherDevices_appSymbolOnly() {
        // This Mac's own level is never shown: macOS has its own battery item (R3).
        let c = label([mac])
        #expect(c.symbol == MenuBarLabelModel.appSymbol && c.text == nil)
        #expect(c.accessibilityLabel == "Levels")
        let charging = label([device(id(1), .mac, "MacBook Pro", level: 50, charging: true)])
        #expect(charging.symbol == MenuBarLabelModel.appSymbol && charging.text == nil)
        let desk = label([device(id(1), .mac, "Mac mini", level: nil)])
        #expect(desk.symbol == MenuBarLabelModel.appSymbol && desk.text == nil)
        #expect(label([]).symbol == MenuBarLabelModel.appSymbol && label([]).text == nil)
    }

    @Test func otherDeviceWithoutLevel_appSymbolOnly() {
        let c = label([mac, device(id(4), .mac, "Mac mini", level: nil)])
        #expect(c.symbol == MenuBarLabelModel.appSymbol && c.text == nil)
    }

    @Test func AC4_iconOnly() {
        let c = label([mac, phone], mode: .iconOnly)
        #expect(c.symbol == MenuBarLabelModel.appSymbol && c.text == nil)
    }

    @Test func AC8_accessibilityLabel() {
        #expect(label([mac, phone]).accessibilityLabel == "Levels: iPhone, 18 percent")
    }

    @Test func noBatteryDeviceNeverChosen() {
        let c = label([mac, device(id(4), .mac, "Mac mini", level: nil), watch])
        #expect(c.symbol == "applewatch")
    }
}
