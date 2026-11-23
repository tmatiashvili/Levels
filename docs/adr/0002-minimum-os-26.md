# ADR-0002: Target only the 26 releases (iOS, iPadOS, macOS, watchOS 26)

- **Status:** Accepted
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0003, ADR-0016, ADR-0017, UI-001…UI-006

## Context

Levels is a personal tool first. The owner's own devices all run the newest systems, and an App Store release is a "maybe, later". Every OS version we support adds `if #available` branches, older-API fallbacks and test matrix cells, and this is a small project spread over four platforms and five extensions.

The 26 releases bring things Levels uses directly:

- **Liquid Glass** across iPhone, iPad, Mac and Apple Watch, including widgets. When the person picks a tinted or clear Home Screen, widgets render in the `accented` rendering mode and the background becomes glass ([Optimizing your widget for accented rendering mode and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)). Supporting only 26 means one visual language, not two.
- **Swift 6 language mode with strict concurrency**, Observation (`@Observable`, iOS 17+), Swift Testing, `AppIntentConfiguration` widgets (iOS 17+), and `SystemFormatStyle.DateReference` for live "5 minutes ago" text in widgets (iOS 18+ / macOS 15+ / watchOS 11+, see [DateReference](https://developer.apple.com/documentation/swiftui/systemformatstyle/datereference)). All are available on 26 with no fallbacks.
- **watchOS Smart Stack** shows widgets, controls and Live Activities ([WWDC25 session 334](https://developer.apple.com/videos/play/wwdc2025/334/)); complications have been WidgetKit widgets since watchOS 9.

Fact found while writing this ADR: Apple shipped the next releases (the 27 line, e.g. macOS 27 "Golden Gate" seen in press coverage and on the owner's Mac, macOS 27.2.1) before today. "Latest only" and "26" are therefore no longer the same thing. The owner settled this (see Decision).

## Decision

The deployment target for every target is the 26 release: iOS 26.0, iPadOS 26.0, macOS 26.0, watchOS 26.0. The code uses Swift 6 language mode with complete strict concurrency checking, SwiftUI, Observation and Swift Testing. There are no `#available` checks for anything older than 26. Raising the floor later, for example to 27, is a one-line change plus a new ADR that supersedes this one.

Owner decision (2026-11-23): the minimum OS stays 26. The 27 releases are out of scope as a floor; apps built for 26 run on 27.

## Options considered

### Option A — 26 only (chosen, owner decision)
- Pros: one design language (Liquid Glass); every API we need is present; smallest test matrix; no availability branches.
- Cons: if Levels goes to the App Store, people on iOS 18 / macOS 15 / watchOS 11 and older can't install it.

### Option B — 26 plus the previous release (iOS 18 / macOS 15 / watchOS 11)
- Pros: larger possible App Store audience.
- Cons: two visual languages for widgets (pre-glass and glass), more previews and test cells, slower building for a personal tool. Rejected by the owner.

### Option C — the 27 releases only
- Pros: matches "latest only" literally as of today.
- Cons: nothing in Levels' current design needs a 27-only API (none was identified while writing the UI ADRs and specs); excludes any owner device that has not updated yet. Rejected by the owner (2026-11-23).

## Consequences

- Positive: simpler code; the UI specs can use Liquid Glass, accented rendering, `DateReference` and `AppIntentConfiguration` without fallbacks.
- Negative / accepted risks: a smaller audience if the App Store happens. App Store review accepts any supported deployment target, so this does not block publishing.
- Follow-ups: when the App Store release is planned, revisit the floor against Apple's published OS adoption numbers.

## Open question (owner)

Closed. Owner decision (2026-11-23): keep the floor at 26; do not move to 27.

## References

- [Optimizing your widget for accented rendering mode and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
- [WWDC25 — What's new in widgets (session 278)](https://developer.apple.com/videos/play/wwdc2025/278/)
- [WWDC25 — What's new in watchOS 26 (session 334)](https://developer.apple.com/videos/play/wwdc2025/334/)
- [What's new in watchOS 26](https://developer.apple.com/watchos/whats-new)
- [SystemFormatStyle.DateReference](https://developer.apple.com/documentation/swiftui/systemformatstyle/datereference)
