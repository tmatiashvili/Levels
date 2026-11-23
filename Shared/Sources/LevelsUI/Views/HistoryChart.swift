import Charts
import LevelsModel
import SwiftUI

/// HIS-001 R8–R10: level over time per battery, charging and Low Power Mode bands, gaps.
/// Colours follow the dataviz reference palette: categorical slots 1–3 for lines, washes for bands.
public struct HistoryChart: View {
    let model: HistoryChartModel
    let range: HistoryRange
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Date?

    public init(model: HistoryChartModel, range: HistoryRange) {
        self.model = model
        self.range = range
    }

    public var body: some View {
        chart
            .overlay {
                if model.isEmpty {
                    VStack(spacing: 4) {
                        Text("No history yet", bundle: .module).font(.headline)
                        Text("Levels records battery levels while it runs.", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(8)
                }
            }
            .accessibilityElement(children: model.isEmpty ? .combine : .contain)
            .accessibilityLabel(accessibilityLabel)
    }

    private var chart: some View {
        Chart {
            ForEach(model.bands) { band in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end),
                              yStart: .value("Bottom", 0), yEnd: .value("Top", 100))
                    .foregroundStyle(HistoryPalette.band(band.kind, colorScheme).opacity(colorScheme == .dark ? 0.22 : 0.16))
            }
            ForEach(model.seriesNames, id: \.self) { name in
                ForEach(Array(model.segments(of: name).enumerated()), id: \.offset) { _, segment in
                    if segment.count == 1, let p = segment.first {
                        PointMark(x: .value("Time", p.date), y: .value("Level", p.level))
                            .foregroundStyle(by: .value("Battery", p.series))
                            .symbolSize(20)
                    } else {
                        ForEach(segment) { p in
                            LineMark(x: .value("Time", p.date), y: .value("Level", p.level),
                                     series: .value("Segment", p.segmentKey))
                                .foregroundStyle(by: .value("Battery", p.series))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            if let selection, !model.isEmpty {
                RuleMark(x: .value("Selected", selection))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(at: selection)
                    }
            }
        }
        .chartForegroundStyleScale(domain: model.seriesNames,
                                   range: model.seriesNames.indices.map { HistoryPalette.series($0, colorScheme) })
        .chartLegend(.hidden)
        .chartXScale(domain: model.domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { if let v = value.as(Int.self) { Text(verbatim: "\(v)%") } }
            }
        }
        .chartXAxis {
            if range == .day {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .chartXSelection(value: $selection)
    }

    private func readout(at date: Date) -> some View {
        let values = model.levels(at: date)
        return VStack(alignment: .leading, spacing: 1) {
            Text(date, format: range == .day ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            if values.isEmpty {
                Text("No reading", bundle: .module).font(.caption2)
            }
            ForEach(values, id: \.series) { v in
                Text(verbatim: model.seriesNames.count > 1 ? "\(v.series) \(v.level) %" : "\(v.level) %")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(4)
        .background(.background, in: RoundedRectangle(cornerRadius: 4))
    }

    private var accessibilityLabel: Text {
        if model.isEmpty { return Text("No history yet", bundle: .module) }
        return Text(verbatim: "\(range.title): \(model.summary ?? "")")
    }
}

/// The legend (HIS-001 R8): lines when there are several, plus each band kind shown.
public struct HistoryLegend: View {
    let model: HistoryChartModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: HistoryChartModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            if model.seriesNames.count > 1 {
                ForEach(Array(model.seriesNames.enumerated()), id: \.offset) { i, name in
                    item(name) {
                        Capsule().fill(HistoryPalette.series(i, colorScheme)).frame(width: 12, height: 3)
                    }
                }
            }
            if model.bands.contains(where: { $0.kind == .charging }) { band(.charging, loc("Charging")) }
            if model.bands.contains(where: { $0.kind == .lowPower }) { band(.lowPower, loc("Low Power Mode")) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func band(_ kind: HistoryChartModel.BandKind, _ title: String) -> some View {
        item(title) {
            RoundedRectangle(cornerRadius: 2)
                .fill(HistoryPalette.band(kind, colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.28))
                .frame(width: 12, height: 10)
        }
    }

    private func item(_ title: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 4) {
            swatch()
            Text(verbatim: title)
        }
    }
}

/// The chart block of a device's detail: chart, legend and summary (no controls, so it
/// also renders off screen with `ImageRenderer`).
public struct DeviceHistoryContent: View {
    let inputs: [HistorySeriesInput]
    let range: HistoryRange
    let now: Date

    public init(inputs: [HistorySeriesInput], range: HistoryRange, now: Date) {
        self.inputs = inputs
        self.range = range
        self.now = now
    }

    public var body: some View {
        let model = HistoryChartModel(series: inputs, range: range, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HistoryChart(model: model, range: range)
                .frame(minHeight: 160)
            HStack(alignment: .firstTextBaseline) {
                HistoryLegend(model: model)
                Spacer(minLength: 8)
                if let summary = model.summary {
                    Text(verbatim: summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A device's history screen (Mac device window, HIS-001 R11): header and the chart,
/// loading the row's batteries through `load`. Reloads when the row changes (a new report).
public struct DeviceHistoryView: View {
    let row: DeviceRowModel
    let load: @Sendable ([DeviceID]) async -> [DeviceID: [HistorySample]]
    @State private var range: HistoryRange = .day
    @State private var samples: [DeviceID: [HistorySample]] = [:]

    public init(row: DeviceRowModel, load: @escaping @Sendable ([DeviceID]) async -> [DeviceID: [HistorySample]]) {
        self.row = row
        self.load = load
    }

    public var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                DeviceRow(row: row, now: context.date)
                Picker(selection: $range) {
                    ForEach(HistoryRange.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Range", bundle: .module) }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                DeviceHistoryContent(inputs: HistorySeriesInput.inputs(for: row, samples: samples),
                                     range: range, now: context.date)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: row) { samples = await load(row.memberIDs) }
    }
}

/// Dataviz reference palette (light / dark steps).
enum HistoryPalette {
    static func series(_ index: Int, _ scheme: ColorScheme) -> Color {
        let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a]
        let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70]
        let list = scheme == .dark ? dark : light
        return Color(hex: list[index % list.count])
    }

    static func band(_ kind: HistoryChartModel.BandKind, _ scheme: ColorScheme) -> Color {
        switch kind {
        case .charging: Color(hex: scheme == .dark ? 0x0ca30c : 0x008300)
        case .lowPower: Color(hex: scheme == .dark ? 0xc98500 : 0xeda100)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
