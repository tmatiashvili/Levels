// The Home Screen and desktop widget background (owner report 2026-11-24: "the widget has no
// glass effect" in the default Home Screen look).
//
// What the platform allows (iOS 27.2 / macOS 26 SDKs, checked 2026-11-24):
// - Real Liquid Glass behind a widget is drawn by the system, and only when the person picks
//   the tinted or clear Home Screen look (or monochrome desktop widgets on the Mac): the widget
//   then renders `.accented` and the system "removes the background and replaces it with a
//   themed glass or tinted color effect" (WidgetKit, "Optimizing your widget for accented
//   rendering mode and Liquid Glass"). It removes exactly what `containerBackground(for: .widget)`
//   declares, so that is where this view goes.
// - In the default (full-colour) look a widget draws its own background, and nothing it draws can
//   see the wallpaper: "A material blurs a background that's part of your app, but not what
//   appears behind your app on the screen. For example, the content on the Home Screen doesn't
//   affect the appearance of a widget." (SwiftUI, `Material`). `glassEffect` has the same limit,
//   and WidgetKit's only glass option, `WidgetTexture.glass`, is visionOS only.
//
// So in full colour this draws the closest look we can: a glass-like platter with a soft sheen
// and a light rim, lighter than the old `.fill.tertiary` slab. It stays opaque so the text keeps
// its contrast whatever the wallpaper is. In the tinted, clear, StandBy and Lock Screen styles the
// system removes it and draws its own glass or nothing.
import SwiftUI

/// The widget's container background. Use as `.containerBackground(for: .widget) { WidgetGlassBackground() }`.
public struct WidgetGlassBackground: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let dark = scheme == .dark
        ZStack {
            // Body: a cool, slightly lit-from-above tone, like glass over a neutral wallpaper.
            LinearGradient(colors: dark ? [Color(white: 0.27), Color(white: 0.15)]
                                        : [Color(white: 0.995), Color(red: 0.90, green: 0.91, blue: 0.93)],
                           startPoint: .top, endPoint: .bottom)
            // Sheen: the soft highlight in the top-leading corner the system glass shows.
            RadialGradient(colors: [Color.white.opacity(dark ? 0.16 : 0.55), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 260)
            // Rim: bright on the lit edge, fainter round the bottom.
            ContainerRelativeShape()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.42 : 0.95),
                                                      Color.white.opacity(dark ? 0.06 : 0.35),
                                                      Color.white.opacity(dark ? 0.20 : 0.70)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1.2)
        }
    }
}
