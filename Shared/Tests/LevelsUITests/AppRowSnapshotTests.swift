// Render harness for the in-app device rows (ring colours). Off by default; to write PNGs:
//
//   LEVELS_APP_SNAPSHOTS=/some/dir swift test --filter AppRowSnapshots
//
// `ImageRenderer` can't draw a `List`, so the rows sit in a plain stack on the list's
// grouped background, one light and one dark sheet.
#if os(macOS)
import AppKit
import ImageIO
import LevelsModel
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LevelsUI

private let outputDir = ProcessInfo.processInfo.environment["LEVELS_APP_SNAPSHOTS"]

@Suite("App row snapshots", .enabled(if: outputDir != nil, "set LEVELS_APP_SNAPSHOTS to a folder"))
@MainActor
struct AppRowSnapshots {
    @Test func renderRowsLightAndDark() throws {
        let dir = URL(fileURLWithPath: try #require(outputDir))
        let now = PreviewFixtures.now
        let charging = DeviceBattery(id: DeviceID(UUID()), name: "Stale charging iPad", kind: .ipad, level: 55,
                                     isCharging: true, updatedAt: now - 3 * 3600)
        let staleLow = DeviceBattery(id: DeviceID(UUID()), name: "Stale low iPhone", kind: .iphone, level: 9,
                                     isCharging: false, updatedAt: now - 3 * 3600)
        let devices = PreviewFixtures.loaded.devices + [charging, staleLow]
        let rows = DeviceRows(devices: devices, thisDeviceID: PreviewFixtures.iPhoneID,
                              preferences: DisplayPreferences(), now: now).rows
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    DeviceRow(row: row, now: now)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    Divider().padding(.leading, 16)
                }
            }
            .frame(width: 380)
            .background(scheme == .light ? Color.white : Color(white: 0.11))
            .padding(16)
            .background(scheme == .light ? Color(white: 0.95) : Color.black)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            try writePNG(image, to: dir.appending(path: "rows-\(scheme == .light ? "light" : "dark").png"))
        }
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
