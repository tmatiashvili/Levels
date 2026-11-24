// DEMO-001 render harness: the iPhone list in demo mode, as Pro and as free. Off by default:
//
//   LEVELS_APP_SNAPSHOTS=/some/dir swift test --filter DemoListSnapshots
//
// `ImageRenderer` can't draw a `List`, so the rows sit in a plain stack (like AppRowSnapshots),
// with the title above and the "Sample devices" banner below.
#if os(macOS)
import AppKit
import ImageIO
import LevelsModel
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LevelsUI

private let outputDir = ProcessInfo.processInfo.environment["LEVELS_APP_SNAPSHOTS"]

@Suite("Demo list snapshots", .enabled(if: outputDir != nil, "set LEVELS_APP_SNAPSHOTS to a folder"))
@MainActor
struct DemoListSnapshots {
    @Test func renderDemoList() async throws {
        let dir = URL(fileURLWithPath: try #require(outputDir))
        let now = Date()
        for tier in DemoTier.allCases {
            let store = DeviceListStore(source: DemoSnapshotSource(now: { now }),
                                        preferences: InMemoryDisplayPreferencesStore(), now: { now }, isHubMode: true)
            tier.configure(store)
            await store.reload()
            for scheme in [ColorScheme.light, .dark] {
                let sheet = DemoListSheet(store: store, now: now, tier: tier, scheme: scheme)
                let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                try writePNG(image, to: dir.appending(path: "demo-list-\(tier.rawValue)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
    }
}

/// The Pro tier sees every row; the free tier goes through the Levels Pro gate (DEMO-001 R9).
enum DemoTier: String, CaseIterable {
    case pro, free

    /// Levels Pro hook: until ProGate is on integration/mac-first the free tier renders like
    /// Pro, marked in the title. Then: `store.gate = ProGate(isPro: false, freeMacID: SampleDevices.macID)`.
    @MainActor func configure(_ store: DeviceListStore) {}

    var title: String { self == .pro ? "Levels Pro" : "Free (gate not merged yet)" }
}

private struct DemoListSheet: View {
    let store: DeviceListStore
    let now: Date
    let tier: DemoTier
    let scheme: ColorScheme

    var body: some View {
        let card = scheme == .light ? Color.white : Color(white: 0.11)
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Levels").font(.largeTitle.bold())
            Text(verbatim: tier.title).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.rows) { row in
                    DeviceRow(row: row, now: now)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    if row.id != store.rows.last?.id { Divider().padding(.leading, 16) }
                }
            }
            .background(card, in: .rect(cornerRadius: 12))
            Spacer(minLength: 24)
            SampleDevicesBanner(onExit: {})
        }
        .padding(16)
        .frame(width: 390, height: 640, alignment: .top)
        .background(scheme == .light ? Color(white: 0.95) : Color.black)
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
