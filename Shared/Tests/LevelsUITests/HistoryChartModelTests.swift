import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

// HIS-001 AC2, AC3, AC8 and R9/R10 on the chart transform.

private func s(_ offset: TimeInterval, _ level: Int, charging: Bool = false, lowPower: Bool = false,
               ends: Bool = false) -> HistorySample {
    HistorySample(date: now.addingTimeInterval(offset), level: level, isCharging: charging,
                  isLowPowerMode: lowPower, endsSegment: ends)
}

private func model(_ samples: [HistorySample], range: HistoryRange = .day) -> HistoryChartModel {
    HistoryChartModel(series: [HistorySeriesInput(name: "Level", samples: samples)], range: range, now: now)
}

@Suite struct HistoryChartModelTests {
    @Test func ac2_twoHourGapSplitsTheLine() {
        let m = model([s(-5 * hour, 90), s(-4.5 * hour, 85), s(-2.5 * hour, 80), s(-2 * hour, 75)])
        #expect(m.segments(of: "Level").count == 2)
    }

    @Test func thirtyMinuteHeartbeatsStayOneLine() {
        let m = model(stride(from: -6 * hour, through: -10 * minute, by: 30 * minute).map { s($0, 70) })
        #expect(m.segments(of: "Level").count == 1)
    }

    @Test func ac3_sleepBreaksTheLine() {
        let m = model([s(-2 * hour, 60), s(-90 * minute, 58, ends: true), s(-60 * minute, 58)])
        #expect(m.segments(of: "Level").count == 2)
    }

    @Test func ac8_chargingBandSpansTheChargingPeriod() {
        let m = model([s(-3 * hour, 40), s(-2 * hour, 40, charging: true), s(-90 * minute, 70, charging: true),
                       s(-1 * hour, 90), s(-50 * minute, 89)])
        let bands = m.bands.filter { $0.kind == .charging }
        #expect(bands.count == 1)
        #expect(bands[0].start == now - 2 * hour)
        #expect(bands[0].end == now - 1 * hour)
    }

    @Test func lowPowerBand() {
        let m = model([s(-3 * hour, 30, lowPower: true), s(-150 * minute, 25)])
        #expect(m.bands == [.init(kind: .lowPower, start: now - 3 * hour, end: now - 150 * minute)])
    }

    @Test func r9_recentLastSegmentRunsToNowOldOneDoesNot() {
        let recent = model([s(-40 * minute, 60), s(-20 * minute, 59)])
        #expect(recent.points.last?.date == now)
        let old = model([s(-3 * hour, 60), s(-2 * hour, 59)])
        #expect(old.points.last?.date == now - 2 * hour)
        let asleep = model([s(-20 * minute, 60, ends: true)])
        #expect(asleep.points.last?.date == now - 20 * minute)
    }

    @Test func r10_emptyWindow() {
        #expect(model([]).isEmpty)
        #expect(model([s(-3 * 86_400, 50)]).isEmpty)  // outside 24 h
        #expect(!model([s(-3 * 86_400, 50)], range: .week).isEmpty)
        #expect(model([]).summary == nil)
    }

    @Test func summaryLowAndHigh() {
        let m = model([s(-3 * hour, 31), s(-2 * hour, 100), s(-1 * hour, 64)])
        #expect(m.low == 31 && m.high == 100)
    }

    @Test func airPodsGroupHasThreeSeriesAndUnionBand() {
        let left = airPod(.left, level: 80), right = airPod(.right, level: 78), cs = airPod(.case, level: 50)
        let row = DeviceRowModel(groupID: airPodsGroup, components: [cs, right, left])
        let samples: [DeviceID: [HistorySample]] = [
            left.id: [s(-2 * hour, 60, charging: true), s(-90 * minute, 90)],
            right.id: [s(-110 * minute, 60, charging: true), s(-70 * minute, 92)],
            cs.id: [s(-2 * hour, 70), s(-90 * minute, 55)],
        ]
        let inputs = HistorySeriesInput.inputs(for: row, samples: samples)
        #expect(inputs.map(\.name) == ["Left", "Right", "Case"])
        let m = HistoryChartModel(series: inputs, range: .day, now: now)
        #expect(m.seriesNames.count == 3)
        #expect(m.bands.filter { $0.kind == .charging } == [.init(kind: .charging, start: now - 2 * hour, end: now - 70 * minute)])
    }

    @Test func singleDeviceUsesRowID() {
        let mac = device(id(1), .mac, "Mac", level: 50)
        let row = DeviceRowModel(record: mac, isThisDevice: true)
        let inputs = HistorySeriesInput.inputs(for: row, samples: [id(1): [s(-1 * hour, 50)]])
        #expect(inputs.count == 1 && inputs[0].samples.count == 1)
    }

    @Test func levelsAtHover() {
        let m = model([s(-2 * hour, 60), s(-90 * minute, 50)])
        #expect(m.levels(at: now - 91 * minute).first?.level == 50)
        #expect(m.levels(at: now - 5 * hour).isEmpty)
    }

    @Test func unsortedInputIsDrawnInTimeOrder() {
        let m = model([s(-1 * hour, 50), s(-2 * hour, 60), s(-90 * minute, 55)])
        #expect(m.points.map(\.level).prefix(3) == [60, 55, 50])
    }

    @Test func summaryIgnoresTheSampleBeforeTheLeftEdge() {
        // 10 % at 24h20m ago rising to 70 % at 23h50m ago: the edge (24h ago) is at 50 %.
        let m = model([s(-(24 * hour + 20 * minute), 10), s(-(23 * hour + 50 * minute), 70), s(-(23 * hour + 30 * minute), 80)])
        #expect(m.low == 50)
        #expect(m.high == 80)
    }
}
