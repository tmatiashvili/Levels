---
id: QA-001
title: v0.1 real-device test plan (Mac + iPhone)
milestone: v0.1
status: Draft
depends_on: [SYNC-001, SYNC-002, RPT-001, RPT-002, MAC-001, MAC-002, UI-001, UI-002, UI-003, UI-004]
adrs: [4, 6, 7, 8, 9, 10, 11, 13, 14, 17, 18, 19]
targets: [Levels-iOS, Levels-Mac, Widgets-iOS, Widgets-Mac]
---

# QA-001: v0.1 real-device test plan (Mac + iPhone)

## Why

The parts of v0.1 most likely to fail are the ones the Simulator can't run: battery readings, silent push delivery, widget reload timing, Shortcuts automations and Mac sleep (ADR-0018). This plan is the manual checklist that proves v0.1 works on real hardware, and it records real numbers so later tuning is based on evidence, not guesses.

## Scope

- In: Mac agent, iPhone app, iPhone Home Screen and Lock Screen widgets, Mac desktop widget, CloudKit sync between them, the "Report Battery" App Intent and Shortcuts automations, "Old devices" with Remove, and "Remove all my data" (both ship in v0.1, UI-002 R11–R12, ADR-0019).
- Out: iPad and Apple Watch (a v0.2 QA spec), accessories (v0.3), alerts (ALR-001), history (HIS-001). Unit-testable logic (throttle, staleness, merge) is covered by Swift Testing per ADR-0018, not here.

## Behaviour

### Setup (do once per run)

- S1 — Hardware: one Mac laptop with a battery (desktop Macs have none), one iPhone. Lead's call (2026-11-23): one Mac laptop + one iPhone is enough to sign off v0.1. Both on the newest OS 26 build. Write down model and OS build of each.
- S2 — Both signed into the same Apple ID with iCloud Drive on. Levels allowed in iCloud settings.
- S3 — Build: owner decision (2026-11-23): every build in the run, including Xcode debug builds, uses the CloudKit **Production** environment (ADR-0005 rule 5, ADR-0018 §6). Before the first run, and after any schema change, deploy the schema in CloudKit Console and check the needed indexes exist. Push environment: Debug builds use `aps-environment = development`; TestFlight and Developer ID builds use `production` (owner decision 2026-11-23). Write down which build type each device runs (debug, TestFlight, Developer ID). If [SPIKE-001](SPIKE-001-debug-build-push-check.md) failed, the iPhone runs a TestFlight build, not an Xcode debug build. Experiments that must not touch the owner's data use a separate container or test setup, not this run.
- S4 — Start state: delete the app from both devices, and in CloudKit Console delete the Levels zone in Production so the run starts clean.
- S5 — On iPhone: add the small Home Screen widget and one Lock Screen widget. On Mac: add the desktop widget. Low Power Mode off unless a case says otherwise.
- S6 — Have a clock with seconds visible. Use CloudKit Console's record view to see `updatedAt` on the server.

### Recording rules

- R1 — Each case is Pass, Fail or Blocked, with date, tester, and a note.
- R2 — Latency cases record observed minutes (to 0.5 min) for each repeat. Don't count a measurement taken while the Levels app is in the foreground: foreground reloads don't use the widget budget and hide the real delay ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)).
- R3 — A run's results are saved as a dated section at the end of this file (or `docs/qa/QA-001-<date>.md`) with the table below. v0.1 is not done until one full run passes all cases marked **Must**.

### Cases

**First run and account**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-01 | Must | Install and launch the Mac agent first, from S4 state. | Menu-bar icon appears; no Dock icon (ADR-0014). Within 1 min, a `DeviceBattery` record for the Mac exists in Console with correct level (±1% of the macOS battery menu) and charging state. |
| QA1-02 | Must | Install and open the iPhone app. | iPhone record created within 1 min. App lists both iPhone and Mac with names, levels and "updated X min ago". iPhone level matches Control Center within 5% (iOS reports in 5% steps). |
| QA1-03 | Must | Look at iPhone widgets right after QA1-02, without opening the app again. | Widget shows both devices once it first loads. Record minutes until the Mac appears. |
| QA1-04 | Must | Quit and relaunch the Mac agent. Reinstall the iPhone app. | No duplicate device rows. Device ID survives reinstall on iPhone (Keychain, ADR-0007); if it doesn't, the old row is shown as stale, not twice as fresh. Note what happened. |
| QA1-05 | Must | Sign out of iCloud on the iPhone, open the app. | Clear message that iCloud is needed. No crash. Cached data either hidden or clearly marked (per UI specs). No write attempts loop (check Console log). |
| QA1-06 | Must | Sign back in, open the app. | Sync resumes without reinstall. Both devices shown within 2 min. |
| QA1-07 | Should | Turn off iCloud for Levels only (Settings > Apple ID > iCloud > apps). | Same as QA1-05. |
| QA1-08 | Should | Mac: sign in with a different Apple ID than the iPhone. | Each device sees only itself. No error loop. (Documents the "same Apple ID" requirement.) |

**Reporting and sync**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-10 | Must | Plug the Mac into power. Watch Console. | Mac record `isCharging` becomes true within 1 min (charging change is reported promptly, RPT/MAC specs). |
| QA1-11 | Must | Unplug the Mac. | `isCharging` false within 1 min. |
| QA1-12 | Must | Plug the iPhone into power with the app in background. | iPhone record updates (if a report path ran) — note whether it did and how long it took. Expected per RPT specs; record minutes. |
| QA1-13 | Must | Leave the Mac on battery, discharging, for 30 min, app untouched. | Mac record `updatedAt` advances at least every ~30 min (heartbeat, ADR-0008 W6). Saves happen about once per 5-point drop plus the heartbeat, never two within 60 s for level changes (ADR-0008 W4). Count saves in Console. |
| QA1-14 | Must | Toggle Mac charging 5 times within 1 min. | Server ends with the correct final state. Charger changes are debounced (3 s) and never saved more than once per 10 s (ADR-0008 W2, floor); the final state is saved within about 15 s of the last toggle. No lost last change. |
| QA1-15 | Should | Turn on Low Power Mode on iPhone, open the app. | `isLowPowerMode` true on the iPhone record. |
| QA1-16 | Should | Change the Mac's name in System Settings > General > Sharing (no in-app rename set). Wait. | New name appears on iPhone after the Mac's next report (SYNC-002 R17). |
| QA1-17 | Must | On the iPhone, rename this iPhone in Levels to "Test Phone". | Within 2 min the Mac popover shows "Test Phone" (rename is written to the iPhone's own record, UI-002 R6). Before the rename the iPhone shows as "iPhone". |

**Silent push and widget latency** (record minutes; repeat each 3 times, at different times of day)

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-20 | Must | iPhone locked, app in background (not force-quit). Plug in the Mac. Note the time. Wake iPhone and look at the widget every minute without opening the app. | Widget shows Mac charging. Record minutes from plug-in to widget change. Pass bar (lead's call 2026-11-23): median ≤ 15 min and no repeat > 60 min. Record whether the silent push arrived (app log). Use the iPhone build type [SPIKE-001](SPIKE-001-debug-build-push-check.md) chose: an Xcode debug build if it passed, a TestFlight build if it failed. |
| QA1-21 | Must | Same as QA1-20, but check the Lock Screen widget. | Record minutes. |
| QA1-22 | Must | Force-quit the iPhone app (swipe up in the app switcher), then repeat QA1-20. | Silent pushes are dropped for a force-quit app ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)). Record what the widget does. Widget still shows "updated X min ago" correctly and the Mac becomes stale on time (ADR-0017). |
| QA1-23 | Must | Change the iPhone's level (use it, or charge it) and watch the Mac desktop widget and menu bar. | Menu bar updates within 1–2 min of the iPhone record changing (Mac agent is always running). Record desktop widget minutes separately. |
| QA1-24 | Should | Make 6 Mac changes in 1 hour (plug/unplug every 10 min). | Record how many silent pushes the iPhone got (app log). Apple says not to expect more than 2–3 per hour; this measures the real number. |

**Network, sleep and staleness**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-30 | Must | Put the iPhone in Airplane Mode. Open the app. | Last known data shown with correct "updated X min ago". No error alert loop; a quiet offline indicator per UI specs. |
| QA1-31 | Must | While in Airplane Mode, plug in the iPhone, then turn Airplane Mode off. | Pending report is sent once network returns (within 1 min of the app next running). |
| QA1-32 | Must | Mac Wi-Fi off for 10 min while on battery, then on. | Mac reports the current state within 1 min of reconnecting. No crash, no error dialog. |
| QA1-33 | Must | Close the Mac lid (sleep) for 1 hour. Watch iPhone. | iPhone keeps showing the Mac's last reading with growing "updated X min ago"; it turns stale at the ADR-0017 threshold. |
| QA1-34 | Must | Open the Mac lid. | Mac reports within 1 min of wake; iPhone shows fresh data after the next push/widget reload. Record minutes. |
| QA1-35 | Must | Restart the Mac and log in. | Agent starts by itself (login item, ADR-0014) and reports within 2 min of login. |
| QA1-36 | Should | Set the iPhone clock 10 min ahead manually, report, then set it back. | "Updated X min ago" never shows a negative time; behaviour matches ADR-0017 clock-skew rules. |
| QA1-37 | Must | Leave the Mac on the charger at 100 % for 2 hours, awake, app untouched. | `updatedAt` advances at least every ~30 min; the iPhone never shows the Mac as stale (65-minute threshold; full on the charger is not "charging" for staleness, ADR-0017). |
| QA1-38 | Should | Plug the iPhone in below 80 %, lock it with the app in the background, and don't open Levels for 1 hour. Watch the Mac popover. | The iPhone row is never shown stale within 2 h of its last report, even while charging (the 30-minute charging rule is for Macs and accessories only, ADR-0017). |

**Shortcuts automation (App Intent)**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-40 | Must | In Shortcuts, run the "Report Battery" action by hand. | Finishes in a few seconds without opening the app. iPhone record `updatedAt` advances. |
| QA1-41 | Must | Create Personal Automations "Battery level falls below 50%" and "rises above 50%" running "Report Battery", set to run without asking. Discharge across 50%. | Automation runs (Shortcuts shows a run) and the record updates. Record minutes from crossing to server update. |
| QA1-42 | Should | Repeat QA1-41 with iPhone locked in a pocket. | Same result; note any notification banner the automation shows. |
| QA1-43 | Should | Leave the phone overnight with automations at 10% steps (per RPT spec). Next morning, compare server history of `updatedAt` with Shortcuts' run log. | Count runs vs. expected crossings; record the gap. |

**Background refresh and data removal**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-50 | Should | Leave the iPhone unused, not charging, app in background for 4 hours. | Record how many background reports happened (BGAppRefreshTask, ADR-0011). Any number is acceptable; this is a measurement. |
| QA1-51 | Must | Run "Remove all my data" on the iPhone, confirm. | Zone gone in Console; app and widgets show the empty state within one reload; the iPhone shows "Reporting is off"; the Mac agent recreates only its own record on its next report (as the confirmation text says, ADR-0019). |
| QA1-52 | Must | Run "Remove all my data" in Airplane Mode. | Error shown; nothing deleted locally or remotely. |
| QA1-53 | Must | After QA1-51, tap "Turn on reporting" on the iPhone. | Zone and subscription exist again; only the iPhone's own record is written by the iPhone (the Mac's record comes from the Mac). |
| QA1-54 | Must | In CloudKit Console, set a test record's `updatedAt` 31 days back (or leave a retired device for 30 days). Open the app and the Mac Settings window. | The device is under "Old devices" on both, not in the main list or widgets. |
| QA1-55 | Must | Remove the old device from QA1-54 on the iPhone; cancel once, then confirm. | Cancel changes nothing. Confirm deletes the record (and its accessories) in Console; the row is gone on both devices after the next fetch. Nothing is removed without confirmation. |
| QA1-56 | Should | Run "Remove all my data" from the Mac Settings window. | Same as QA1-51, with the roles swapped. |

**Release gate**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA1-60 | Must | Run QA1-01, -02 and -20 with an Xcode debug build on the iPhone (a TestFlight build if [SPIKE-001](SPIKE-001-debug-build-push-check.md) failed) and the Developer ID build on the Mac, after deploying the schema. | Both devices see each other (both on Production). Subscriptions fire. No `unknownItem` or schema errors. |
| QA1-61 | Must | Archive each target and open Xcode's privacy report. | Matches ADR-0019: no collected data, only the declared required-reason APIs. |

### Result table (copy per run)

| Run date | Tester | Devices + OS builds | Build type | Case | Result | Observed minutes (r1 / r2 / r3) | Notes |
|---|---|---|---|---|---|---|---|

## Design

No code. **Builder's call:** add a hidden "Diagnostics" log screen (or `Logger` subsystem `Levels` viewable in Console.app) that prints push arrivals, reports sent, throttle skips and widget reload calls with timestamps, so QA1-20/24/43/50 can be measured without Xcode attached. Logs keep device names private (ADR-0019).

## Edge cases and failure modes

- Desktop Mac with no battery: out of scope for v0.1 tests; note what the agent shows.
- Focus modes and Low Power Mode may delay background work; when a latency case looks slow, write down whether either was on.
- A run with Xcode attached changes background behaviour. **Assumption:** the debugger keeps the app from suspending; run latency cases with the debugger detached.
- Results vary a lot by time of day and usage. Three repeats is a minimum, not a statistic.

## Acceptance criteria

- [ ] AC1 — Given a clean start (S4), when all **Must** cases are run on one Mac laptop and one iPhone, then each passes or has a linked issue that the owner accepts for v0.1.
- [ ] AC2 — Given QA1-20, -21, -23, -34 and -41, when each is run three times, then observed minutes are recorded for every repeat, and QA1-20 meets the pass bar (median ≤ 15 min, none > 60 min).
- [ ] AC3 — Given QA1-60, when a debug build (or, if [SPIKE-001](SPIKE-001-debug-build-push-check.md) failed, a TestFlight build) on the iPhone and a Developer ID build on the Mac run after schema deployment, then they sync with each other in Production and the iPhone receives the silent push.
- [ ] AC4 — Given QA1-61, then each target's privacy report matches ADR-0019.

## Tests

All cases are manual on real hardware, because they depend on battery hardware, APNs, WidgetKit budgets, Shortcuts and sleep, none of which the Simulator reproduces (ADR-0018). Logic behind them (throttle, staleness, merge) has Swift Testing unit tests in the owning specs.

## Open questions

- None. Lead's calls (2026-11-23): one Mac laptop + one iPhone is enough for v0.1 sign-off (S1); the widget-latency pass bar is median ≤ 15 min in QA1-20 and no repeat over 60 min (QA1-20, AC2).
