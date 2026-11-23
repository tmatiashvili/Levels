---
id: RPT-002
title: "Report Battery" App Intent and Shortcuts automations
milestone: v0.1
status: Draft
depends_on: [RPT-001, SYNC-001]
adrs: [8, 10, 11]
targets: [Levels-iOS]
---

# RPT-002: "Report Battery" App Intent and Shortcuts automations

## Why

The iPhone app is asleep most of the time, so its battery in iCloud goes stale. Shortcuts can run an action whenever the battery crosses a level or the charger is plugged in or out, without opening the app and without asking. This spec gives Shortcuts that action and tells the owner how to set it up once.

## Scope

- In: `ReportBatteryIntent`; the `AppShortcutsProvider`; the user-facing setup guide; the in-app hint that points to it.
- Out (and where it goes instead): reading and sending the battery → RPT-001 (`BatteryReporter`). iPad → RPT-003 (same intent, same app). Watch → RPT-004 (no automations there, ADR-0012). A Mac intent → MAC-* if wanted (macOS 26 has personal automations).

## Behaviour

- **R1** The intent is titled "Report Battery" and takes **no parameters**.
- **R2** It runs entirely in the background: `supportedModes = .background`. It never opens the app.
- **R3** It calls `BatteryReporter.reportNow(reason: .appIntent)` (RPT-001). `.appIntent` is an urgent reason, so SYNC-001 saves at once even if the level changed by less than 5 points (SYNC-001 R5a, ADR-0008 W9). It waits at most **10 seconds**. If the hand-off has not finished by then, the intent still returns success; SYNC-001 owns any retry.
- **R4** It returns no value and shows no dialog or snippet, so automations stay silent.
- **R5** It throws (so Shortcuts shows the failure) only when `reportNow` throws `ReportError.iCloudUnavailable` (RPT-001; SYNC-001 status `.signedOut` or `.restricted`). All other errors are logged and swallowed; the next trigger retries.
- **R6** An unknown reading (RPT-001 R3) is not an error: the intent returns success and sends nothing.
- **R7** It is discoverable in Shortcuts and Spotlight and has one App Shortcut with the phrases in Design.
- **R8** The app shows a setup hint card (Design → In-app hint) until an automation run is seen. It counts as seen when `rpt.lastReport["appIntent"]` (RPT-001 R10) is less than 7 days old. (A manual run from Shortcuts also counts; that's fine.) The owner can also dismiss it; then it moves to Settings → "Background updates".
- **R9** The card stays hidden on the watch and on Mac.

## Design

```swift
struct ReportBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Report Battery"
    static let description = IntentDescription(
        "Sends this device's battery level to your other devices through iCloud.")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true

    @Dependency var reporter: BatteryReporter   // registered at app start (RPT-001)

    func perform() async throws -> some IntentResult
}

struct LevelsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReportBatteryIntent(),
            phrases: [
                "Report battery with \(.applicationName)",
                "Update \(.applicationName)",
                "Send my battery to \(.applicationName)"
            ],
            shortTitle: "Report Battery",
            systemImageName: "battery.100percent")
    }
}
```

- `perform()` races `reporter.reportNow(.appIntent)` against a 10 s sleep in a task group (R3). On `ReportError.iCloudUnavailable` it throws `ReportBatteryError.iCloudUnavailable` with a `LocalizedStringResource` message: "Turn on iCloud for Levels in Settings."
- Register the reporter with `AppDependencyManager.shared.add { … }` in the `App` init, before any intent can run.
- The intent lives in the Levels-iOS target (same process as the app, shares `BatteryReporter`). **Builder's call:** move it into Shared later if the Mac wants it too.
- `openAppWhenRun` is deprecated; do not use it ([forum 804015](https://developer.apple.com/forums/thread/804015)).
- No Info.plist keys needed beyond RPT-001.

### In-app hint

A card at the top of the device list, iPhone and iPad only:

> **Keep this iPhone up to date**
> iOS pauses Levels in the background. Add a few Shortcuts automations so your other devices see this battery change. Takes 3 minutes.
> [Show me how] [Open Shortcuts] [Not now]

- "Show me how" opens the guide below as an in-app sheet.
- "Open Shortcuts" is a `ShortcutsLink` ([docs](https://developer.apple.com/documentation/appintents/shortcutslink)). It opens Levels' page in Shortcuts. **Assumption:** there is no public way to open the "new automation" screen directly.
- Settings → "Background updates" shows the guide and "Last background report: 12 min ago (Shortcuts)" from `rpt.lastReport`.

### Setup guide (user-facing text)

> **Set up background updates (once per iPhone or iPad)**
>
> You'll make 7 automations. They all run "Report Battery".
>
> 1. Open the **Shortcuts** app and tap **Automation**.
> 2. Tap **+**, then choose **Charger**. Tick **Is Connected** and **Is Disconnected**. Choose **Run Immediately**. Tap **Next**.
> 3. Search for **Report Battery** (Levels) and pick it. Tap **Done**.
> 4. Tap **+** again and choose **Battery Level**. Pick **Falls Below** and set **80%**. Choose **Run Immediately**, tap **Next**, pick **Report Battery**, tap **Done**.
> 5. Repeat step 4 for **Falls Below 60%**, **40%** and **20%**.
> 6. Repeat step 4 with **Rises Above 50%** and **Rises Above 90%**.
> 7. If Shortcuts asks about notifications, turn **Notify When Run** off.
>
> Want finer updates? Add more steps, e.g. every 10%. Each automation runs only when the battery crosses its level, so more of them cost almost nothing.

Why this set: the Charger automation catches the two moments that matter most. Four "falls below" steps keep the record within 20% while the battery drains, which is when people check. Two "rises above" steps cover charging, where the "on power" flag already tells the story. **Assumption:** the slider allows these exact values and both Charger options fit in one automation (ADR-0011).

## Edge cases and failure modes

- **App force-quit:** **Assumption:** the system still launches the app process in the background for the intent.
- **Device locked:** **Assumption:** automations and the intent run while locked; CloudKit works after first unlock.
- **Low Power Mode:** **Assumption:** automations still run. The reported reading carries `isLowPowerMode`.
- **Several automations fire close together** (plug in at 79%): each runs the intent; ADR-0008's 10 s floor merges them into one write.
- **Setup never done:** the card stays (R8). Freshness falls back to RPT-001 triggers.
- **Automations lost** (new phone, restore): automations are per device and don't sync ([Add automations](https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios)); the card returns after 7 days without an automation run.
- **Shortcuts asks before running** (if "Run Immediately" wasn't chosen): the owner sees a prompt; the guide says to pick Run Immediately.

## Acceptance criteria

- [ ] AC1 — Given `ReportBatteryIntent`, then it has no `@Parameter` properties and `supportedModes == .background`.
- [ ] AC2 — Given a fake reporter that succeeds, when `perform()` runs, then the reporter was called once with `.appIntent` and the result has no value and no dialog.
- [ ] AC3 — Given a fake reporter that never returns, when `perform()` runs, then it returns success within 11 s.
- [ ] AC4 — Given SYNC reports "iCloud unavailable", when `perform()` runs, then it throws `iCloudUnavailable`.
- [ ] AC5 — Given SYNC throws a network error, when `perform()` runs, then it returns success.
- [ ] AC6 — Given `rpt.lastReport["appIntent"]` is 2 days old, when the device list shows, then the hint card is hidden; given it is 8 days old or absent, then the card shows.
- [ ] AC7 — Given the Shortcuts app on a real iPhone, when the owner searches "Report Battery", then the Levels action appears; when run from Shortcuts, then Levels does not come to the foreground.
- [ ] AC8 — Given a "Charger — Run Immediately" automation on a real iPhone with Levels in the background, when the charger is plugged in, then no prompt or banner appears, and within 2 minutes another device shows this iPhone on power.
- [ ] AC9 — Given a "Battery Level Falls Below 80% — Run Immediately" automation on a real iPhone, when the battery drains from 81% to 79% with the app not opened, then this iPhone's record updates without the app being opened.
- [ ] AC10 — Given Siri on a real iPhone, when the owner says "Report battery with Levels", then the intent runs.

## Tests

- **Unit (Swift Testing):** AC1–AC6 with a fake reporter and a fake clock.
- **Real hardware only:** AC7–AC10. Automations, Siri and real battery levels don't exist on the Simulator; the Simulator battery is unknown (ADR-0010). AC9 needs a slow drain (play video) and takes time; run it once per OS major version.

## Open questions

- None. Owner decision (2026-11-23): the owner will set up the 7 automations above on each iPhone and iPad. (The minimum useful set, if ever needed, stays Charger + Falls Below 50% + Falls Below 20%.)
