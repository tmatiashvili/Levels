import Foundation
import LevelsModel
import SwiftUI
import Testing
@testable import LevelsUI

@Suite("UI-001 row text, symbols, layout")
struct RowTextTests {
    func row(_ d: DeviceBattery) -> DeviceRowModel { DeviceRowModel(record: d, isThisDevice: false) }

    @Test func AC6_chargingMacAccessibilityLabel() {
        let mac = row(device(id(2), .mac, "MacBook Pro", level: 45, charging: true, age: 5 * minute))
        #expect(RowText.accessibilityLabel(for: mac, now: now, locale: en)
                == "MacBook Pro, 45 percent, charging, updated 5 minutes ago")
    }

    @Test func R9_lowPowerModeInLabel() {
        let phone = row(device(id(1), .iphone, "iPhone", level: 62, lowPower: true, age: 2 * minute))
        #expect(RowText.accessibilityLabel(for: phone, now: now, locale: en)
                == "iPhone, 62 percent, low power mode, updated 2 minutes ago")
    }

    @Test func R6_staleLabelEndsOutOfDateAndDropsCharging() {
        let watch = row(device(id(3), .watch, "Apple Watch", level: 81, charging: true, age: 3 * hour))
        #expect(RowText.accessibilityLabel(for: watch, now: now, locale: en)
                == "Apple Watch, 81 percent, updated 3 hours ago, out of date")
    }

    @Test(arguments: [(20, true), (21, false), (0, true), (100, false)])
    func AC7_lowAtOrBelow20(level: Int, low: Bool) {
        let r = row(device(id(2), .mac, "Mac", level: level))
        #expect(r.isLow == low)
        #expect(RowText.accessibilityLabel(for: r, now: now, locale: en).contains(", low,") == low)
    }

    @Test func AC7_lowWord() { #expect(RowText.low(locale: en) == "Low") }

    @Test func AC13_noBatteryRow() {
        let iMac = row(device(id(5), .mac, "iMac", level: nil, age: 5 * minute))
        #expect(!iMac.hasBattery)
        #expect(!iMac.isLow)
        #expect(DeviceSymbol.symbolName(kind: .mac, accessoryKind: nil, hasBattery: iMac.hasBattery) == "desktopcomputer")
        #expect(RowText.noBattery(locale: en) == "Plugged in · no battery")
        #expect(RowText.accessibilityLabel(for: iMac, now: now, locale: en)
                == "iMac, plugged in, no battery, updated 5 minutes ago")
    }

    @Test func AC14_groupLabelNamesEachComponent() {
        let r = rows([airPod(.left, level: 40), airPod(.right, level: 35), airPod(.case, level: 80)]).rows[0]
        #expect(RowText.accessibilityLabel(for: r, now: now, locale: en)
                == "AirPods Pro, left 40 percent, updated 5 minutes ago, right 35 percent, updated 5 minutes ago, case 80 percent, updated 5 minutes ago")
    }

    @Test(arguments: [
        (0.0, "now"), (59.0, "now"), (60.0, "1 minute ago"), (5 * minute, "5 minutes ago"),
        (3 * hour, "3 hours ago"), (2 * day, "2 days ago"), (-120.0, "now"),
    ])
    func R8_ageText(age: TimeInterval, expected: String) {
        let reading = DeviceBattery(id: id(1), name: "D", kind: .iphone, level: 1, isCharging: false, updatedAt: now - age)
        #expect(AgeFormatting.text(readingDate: reading.readingDate(now: now), now: now, locale: en) == expected)
    }

    @Test func R5_percentFormat() {
        #expect(RowText.percent(62, locale: en) == "62%")
    }

    @Test(arguments: [
        (DeviceKind.iphone, AccessoryKind?.none, true, "iphone"),
        (.ipad, nil, true, "ipad"),
        (.mac, nil, true, "laptopcomputer"),
        (.watch, nil, true, "applewatch"),
        (.accessory, .airpods, true, "airpods"),
        (.accessory, .mouse, true, "magicmouse"),
        (.accessory, .keyboard, true, "keyboard"),
        (.accessory, .trackpad, true, "rectangle.and.hand.point.up.left"),
        (.accessory, nil, true, "headphones"),
    ])
    func symbolTable(kind: DeviceKind, accessory: AccessoryKind?, hasBattery: Bool, symbol: String) {
        #expect(DeviceSymbol.symbolName(kind: kind, accessoryKind: accessory, hasBattery: hasBattery) == symbol)
    }

    @Test(arguments: [(DynamicTypeSize.large, false), (.xxxLarge, false), (.accessibility1, true), (.accessibility3, true)])
    @MainActor func AC11_stacksAtAccessibilitySizes(size: DynamicTypeSize, stacked: Bool) {
        #expect(DeviceRow.isStacked(size) == stacked)
    }

    @Test func R11_bannerVisibility() {
        #expect(SyncStatusBanner.isVisible(state: .noICloud, isReportingOff: false))
        #expect(SyncStatusBanner.isVisible(state: .syncError("x"), isReportingOff: false))
        #expect(SyncStatusBanner.isVisible(state: .loaded, isReportingOff: true))
        #expect(!SyncStatusBanner.isVisible(state: .loaded, isReportingOff: false))
        #expect(!SyncStatusBanner.isVisible(state: .empty, isReportingOff: false))
    }

    @Test func removeConfirmationText() {
        #expect(OldDevicesSection.removeTitle("Old iPad") == "Remove Old iPad? It will come back if that device runs Levels again.")
    }
}
