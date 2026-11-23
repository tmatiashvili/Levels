# ADR-0011: Report iPhone and iPad battery from foreground, Shortcuts automations, background refresh and push wake-ups

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0006, ADR-0008, ADR-0009, ADR-0010, RPT-001, RPT-002, RPT-003, SYNC-001

## Context

iOS suspends the app soon after it leaves the screen. A suspended app gets no battery notifications (ADR-0010). So without help, the iPhone's own record in CloudKit only changes when the owner opens Levels, and other devices show a stale iPhone level. This is the hard part of the product.

Verified facts:

- **Shortcuts automations.** Apple lists **Battery Level** and **Charger** among the personal automations that "can be run automatically", i.e. without asking for confirmation. When set to run without asking, "the automation will not notify you when it's triggered." ([Add automations](https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios))
- The Battery Level trigger has three options: **Equals**, **Rises Above** and **Falls Below**, each against "the value set in the percentage slider". ([Setting triggers](https://support.apple.com/guide/shortcuts/apde31e9638b/ios)) Shortcuts 26 still has it ("When battery level rises above 50%"), and macOS 26 gains personal automations too. ([What's new in Shortcuts 26](https://support.apple.com/125148))
  - **Assumption:** the slider moves in 5% or 1% steps; any multiple of 10 is selectable.
  - **Assumption:** the Charger trigger offers "Is Connected" and "Is Disconnected", and both can be ticked in one automation.
  - **Assumption:** the Battery Level trigger and "Run Immediately" behave the same on iPadOS 26 (Apple's page covers "iPhone or iPad" but does not list per-device triggers).
  - **Assumption:** the Battery Level trigger fires each time the threshold is crossed, every day, not once.
  - **Assumption:** automations still fire in Low Power Mode.
- **App Intents in the background.** In iOS 26, `AppIntent.supportedModes` sets where an intent runs; `.background` means "run the action entirely in the background". ([supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)) `openAppWhenRun` is deprecated in favour of `supportedModes` (Apple DTS, [forum 804015](https://developer.apple.com/forums/thread/804015)). App Intents run in the app's process. So an automation can run "Report Battery" without opening the app.
- **BGAppRefreshTask** is for "small bits of information" and needs the `fetch` background mode. ([BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask)) The system picks when, and Low Power Mode pauses background activity ([isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)).
  - **Assumption:** no refresh runs after the user force-quits the app or turns off Background App Refresh.
- **Silent push** wakes the app for up to 30 seconds. Delivery is not guaranteed; the system may throttle; Apple advises no more than two or three per hour. ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app))
- **Widgets** reload on a budget of about 40–70 times a day for a widget the user views often, roughly every 15–60 minutes, and the extension "is not continually active". ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date))
  - **Assumption:** `UIDevice` battery values can be read inside a widget extension. Not verified.
- **Battery state notifications** arrive only while the process runs (ADR-0010).

## Decision

Use five triggers. All of them call the same `BatteryReporter.reportNow(reason:)` (RPT-001), which reads through `BatteryReader` and hands a `DeviceBattery` to `BatterySyncService.report(_:reason:)` (SYNC-001). Launch, App Intent and charger reasons are urgent (ADR-0008 W9). Write throttling and "skip unchanged" stay in SYNC (ADR-0008).

| # | Trigger | Reliability | Role |
|---|---|---|---|
| 1 | App launch, foreground, and in-process battery notifications while running | Certain, but only when the owner uses the app | Baseline |
| 2 | **"Report Battery" App Intent run by Shortcuts automations** on Battery Level thresholds and Charger connect/disconnect, set to run immediately | High once set up; needs one-time manual setup per device | **Primary background path** |
| 3 | `BGAppRefreshTask`, requested every time the app goes to background, earliest 30 min ahead | Low and irregular; zero in Low Power Mode or after force-quit | Best-effort top-up |
| 4 | Silent push from another device's change (ADR-0006) — also report self while awake | Opportunistic; not guaranteed | Free top-up |
| 5 | `UIDevice.batteryStateDidChangeNotification` | Only while running | Covered by #1 |

What we promise honestly: with trigger #2 set up, the iPhone's record is at most one threshold step behind the real level, and charging start/stop shows within seconds to minutes. Without #2, the record is only fresh after the owner opens the app. The UI's "updated X min ago" (README) stays the safety net. A long gap with no report can also mean the level simply did not cross a threshold.

Rejected for v0.1: reading battery in the widget's timeline provider, background location or audio tricks, `BGProcessingTask`.

iPad follows the same rules (RPT-003).

## Options considered

### Option A — foreground only
- Pros: trivial; always works.
- Cons: the iPhone is stale whenever the owner is not looking at Levels, which is most of the time. The whole point of the app fails for the iPhone's own entry.

### Option B — BGAppRefreshTask
- Pros: no user setup.
- Cons: the system decides when, based on how often the app is used. A tool you glance at in a widget is rarely opened, so it gets little time. Paused in Low Power Mode, exactly when battery matters. Not a primary path.

### Option C — App Intent + Shortcuts automations (chosen as primary)
- Pros: driven by the event we care about (the level crossing a step, the charger); runs without opening the app and without a prompt; no system scheduling luck; uses public API, so App Store safe.
- Cons: the owner must create several automations by hand on each iPhone and iPad; the app cannot create them or check that they exist. Automations are per device and don't sync. Shortcuts can change between OS releases.

### Option D — Charger events
- Pros: charging start/stop is the most useful moment to report.
- Cons: `batteryStateDidChangeNotification` only arrives while running. Fix: use the Shortcuts **Charger** trigger with the same intent (part of Option C).

### Option E — report self on silent push (chosen as extra)
- Pros: costs nothing extra; the app is already awake; often lands right after the Mac or watch reports.
- Cons: not guaranteed; can create a ping-pong between devices unless SYNC skips unchanged readings (ADR-0008). This option depends on that rule.

### Option F — read battery in the widget timeline provider
- Pros: widgets reload 40–70 times a day without user setup.
- Cons: not verified that `UIDevice` battery works in an extension; extensions should not do CloudKit writes (short life, budget); ADR-0009 makes the App Group cache app-written; adds a second writer. Revisit only if A–E prove too stale. **Rejected for v0.1.**

### Option G — keep-alive tricks (background location, silent audio)
- Pros: continuous running.
- Cons: App Store rejection, real battery cost, against the owner's simplicity goal. **Rejected.**

## Consequences

- Positive: event-driven reporting with no server and no private API; one code path for all triggers.
- Negative / accepted risks: freshness depends on the owner completing the Shortcuts setup (RPT-002 adds a guide and an in-app hint). Silent pushes and background refresh may never come.
- Follow-ups: after two weeks of real use, compare `updatedAt` gaps with and without automations; revisit Option F if needed. Confirm the Assumptions above on a real iPhone and iPad on iOS 26.

## References

- [Add automations to Shortcuts on iPhone or iPad](https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios)
- [Shortcuts: setting triggers](https://support.apple.com/guide/shortcuts/apde31e9638b/ios)
- [What's new in Shortcuts for iOS, iPadOS, macOS, watchOS 26](https://support.apple.com/125148)
- [AppIntent.supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)
- [Forum: openAppWhenRun deprecated](https://developer.apple.com/forums/thread/804015)
- [BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask), [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
