// Render harness for the widget rendering modes (Liquid Glass review 2026-11-24). Off by
// default; to write PNGs:
//
//   LEVELS_WIDGET_SNAPSHOTS=/some/dir swift test --filter WidgetSnapshots
//
// `ImageRenderer` draws the views but not the widget host, so the harness imitates what the
// host does to the pixels (Apple, "Optimizing your widget for accented rendering mode and
// Liquid Glass"): accented (tinted and clear Home Screen, Mac desktop behind windows) keeps
// only each pixel's opacity and paints it one colour; vibrant (Lock Screen, StandBy at night)
// keeps only luminance. Good enough to catch content that vanishes or merges in those styles.
#if os(macOS) && DEBUG  // the gallery is Debug-only (WidgetRenderGallery.swift)
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WidgetKit
@testable import LevelsWidgetKit

private let outputDir = ProcessInfo.processInfo.environment["LEVELS_WIDGET_SNAPSHOTS"]

/// The host styles the harness imitates.
private enum HostStyle: String, CaseIterable {
    case defaultLight = "1-default-light"
    case defaultDark = "2-default-dark"
    case clear = "3-clear-glass"
    case tinted = "4-tinted"
    case vibrant = "5-vibrant-lockscreen"

    var mode: WidgetRenderingMode {
        switch self {
        case .defaultLight, .defaultDark: .fullColor
        case .clear, .tinted: .accented
        case .vibrant: .vibrant
        }
    }

    var scheme: ColorScheme { self == .defaultLight ? .light : .dark }

    /// What the content becomes on the host.
    @MainActor @ViewBuilder func composite(_ content: CGImage, size: CGSize) -> some View {
        let image = Image(decorative: content, scale: 2)
        switch self {
        case .defaultLight, .defaultDark:
            image
        case .clear:
            Color.white.mask(image)
        case .tinted:
            Color(red: 1.0, green: 0.86, blue: 0.62).mask(image)
        case .vibrant:
            // Luminance times the pixel's own opacity.
            Color.white.mask(image).mask(image.luminanceToAlpha())
        }
    }

    /// The widget's own background on the host (Home Screen styles only).
    @MainActor @ViewBuilder func plate(accessory: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: accessory ? 12 : 22, style: .continuous)
        switch self {
        // Full colour: the widget's own container background. `ContainerRelativeShape` has no
        // container outside the host, so clip it to the widget's corners here.
        case .defaultLight, .defaultDark:
            if accessory { Color.clear } else { WidgetGlassBackground().clipShape(shape) }
        case .clear: shape.fill(Color.white.opacity(0.10)).overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
        case .tinted: shape.fill(Color(red: 0.30, green: 0.20, blue: 0.08).opacity(0.85))
        case .vibrant: Color.clear
        }
    }

    /// The wallpaper behind the widgets.
    var wallpaper: some View {
        switch self {
        case .defaultLight:
            LinearGradient(colors: [Color(red: 0.62, green: 0.78, blue: 0.95), Color(red: 0.93, green: 0.80, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .defaultDark, .tinted:
            LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.18, green: 0.10, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .clear, .vibrant:
            LinearGradient(colors: [Color(red: 0.20, green: 0.45, blue: 0.70), Color(red: 0.85, green: 0.45, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

@MainActor
private func render<V: View>(_ view: V, scheme: ColorScheme) -> CGImage? {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
    renderer.scale = 2
    return renderer.cgImage
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

@Suite("Widget snapshots", .enabled(if: outputDir != nil, "set LEVELS_WIDGET_SNAPSHOTS to a folder"))
@MainActor
struct WidgetSnapshots {
    @Test func renderEveryFamilyInEveryStyle() throws {
        let dir = URL(fileURLWithPath: try #require(outputDir))
        for style in HostStyle.allCases {
            var tiles: [(GalleryFamily, CGImage)] = []
            for family in GalleryFamily.allCases {
                let content = try #require(render(GalleryCell(family: family, mode: style.mode), scheme: style.scheme))
                let tile = ZStack {
                    style.plate(accessory: family.isAccessory)
                    style.composite(content, size: family.size)
                }
                .frame(width: family.size.width, height: family.size.height)
                let png = try #require(render(tile.padding(12).background(style.wallpaper), scheme: style.scheme))
                try writePNG(png, to: dir.appending(path: "\(style.rawValue)/\(family.rawValue).png"))
                tiles.append((family, png))
            }
            // One contact sheet per style.
            let home = tiles.filter { !$0.0.isAccessory }
            let lock = tiles.filter { $0.0.isAccessory }
            let sheet = VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(home.prefix(3), id: \.0) { Image(decorative: $0.1, scale: 2) }
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(home.dropFirst(3), id: \.0) { Image(decorative: $0.1, scale: 2) }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lock, id: \.0) { Image(decorative: $0.1, scale: 2) }
                    }
                }
            }
            .background(style.wallpaper)
            let sheetPNG = try #require(render(sheet, scheme: style.scheme))
            try writePNG(sheetPNG, to: dir.appending(path: "sheet-\(style.rawValue).png"))
        }
    }
}
#endif
