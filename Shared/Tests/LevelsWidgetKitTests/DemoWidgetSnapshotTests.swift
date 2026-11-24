// DEMO-001 render harness: the iPhone widget in demo mode (small, medium, large). Off by
// default:
//
//   LEVELS_WIDGET_SNAPSHOTS=/some/dir swift test --filter DemoWidgetSnapshots
#if os(macOS) && DEBUG  // GalleryFamily is Debug-only (WidgetRenderGallery.swift)
import AppKit
import ImageIO
import LevelsModel
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WidgetKit
@testable import LevelsWidgetKit

private let outputDir = ProcessInfo.processInfo.environment["LEVELS_WIDGET_SNAPSHOTS"]

@Suite("Demo widget snapshots", .enabled(if: outputDir != nil, "set LEVELS_WIDGET_SNAPSHOTS to a folder"))
@MainActor
struct DemoWidgetSnapshots {
    @Test func renderDemoWidgets() throws {
        let dir = URL(fileURLWithPath: try #require(outputDir))
        let now = Date()
        let entry = try #require(DemoWidgetPlan.timeline(snapshot: SampleDevices.snapshot(now: now), now: now,
                                                         selection: nil).entries.first)
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    tile(.smallLow, entry: entry, scheme: scheme)
                    tile(.smallCharging, entry: DeviceEntry(date: now, snapshot: entry.snapshot,
                                                            preferences: DisplayPreferences(),
                                                            selection: SampleDevices.macID), scheme: scheme)
                }
                tile(.medium, entry: entry, scheme: scheme)
                tile(.large, entry: entry, scheme: scheme)
            }
            .padding(20)
            .background(LinearGradient(colors: scheme == .light
                                       ? [Color(red: 0.62, green: 0.78, blue: 0.95), Color(red: 0.93, green: 0.80, blue: 0.85)]
                                       : [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.18, green: 0.10, blue: 0.20)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            try writePNG(image, to: dir.appending(path: "demo-widget-\(scheme == .light ? "light" : "dark").png"))
        }
    }

    private func tile(_ family: GalleryFamily, entry: DeviceEntry, scheme: ColorScheme) -> some View {
        family.view(entry: entry)
            .padding(family.padding)
            .frame(width: family.size.width, height: family.size.height)
            .environment(\.widgetRenderingMode, .fullColor)
            .environment(\.isWidgetRenderHarness, true)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(scheme == .light ? Color(white: 0.96) : Color(white: 0.14)))
    }
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
#endif
