---
id: QA-002
title: v0.2 real-device test plan (iPad + Apple Watch)
milestone: v0.2
status: Draft
depends_on: [QA-001, RPT-003, RPT-004, UI-005, UI-006]
adrs: [5, 6, 8, 9, 11, 12, 17, 18]
targets: [Levels-iOS, Levels-Watch, Widgets-iOS, Widgets-Watch]
---

# QA-002: v0.2 real-device test plan (iPad + Apple Watch)

## Why

v0.2 adds the iPad and the Apple Watch. The risky parts are again the ones the Simulator can't run: the watch's background refresh budget, complication reloads, silent push on watchOS, the iPad's multi-window reporting, and sync across more than two devices (ADR-0018). This plan proves v0.2 on real hardware and records real numbers, like QA-001 did for v0.1.

## Scope

- In: iPad reporting (RPT-003) and iPad layout (UI-005); watch reporting (RPT-004), watch app and watch widgets (UI-006); watch background refresh with a complication on the daily face (ADR-0012); sync between the Mac, the iPhone, the iPad and the Watch.
- Out: everything QA-001 already covers on Mac and iPhone (re-run only QA1-01, -20 and -60 as a regression check); accessories (v0.3); alerts (ALR-001); history (HIS-001).

## Behaviour

### Setup (do once per run)

- S1 — Hardware: the QA-001 Mac laptop and iPhone, plus one iPad and one Apple Watch paired with that iPhone. All on the newest OS 26 build. Write down model and OS build of each.
- S2 — All signed into the same Apple ID with iCloud on and Levels allowed in iCloud settings. The watch has its own network path for some cases (known Wi-Fi).
- S3 — Build: every build, including Xcode debug builds, uses the CloudKit **Production** environment (ADR-0005 rule 5, ADR-0018 §6). Debug builds use `aps-environment = development`, TestFlight and Developer ID builds `production`; if [SPIKE-001](SPIKE-001-debug-build-push-check.md) failed, the iPhone runs a TestFlight build. Deploy the schema first if it changed since QA-001. Write down the build type on each device.
- S4 — Start state: the QA-001 end state is fine. Install Levels on the iPad and the Watch. On the iPad, set up the 7 Shortcuts automations (RPT-002, owner decision 2026-11-23).
- S5 — Watch face: put a Levels complication on the face the owner wears daily (owner decision 2026-11-23; operating assumption for ADR-0012 and RPT-004). On the iPad: add the small Home Screen widget and one Lock Screen widget.
- S6 — Turn on the Diagnostics log (QA-001 Design) on every device, so report, push and refresh times can be read without Xcode attached.

### Recording rules

Same as QA-001 R1–R3. Results go in a dated section at the end of this file (or `docs/qa/QA-002-<date>.md`). v0.2 is not done until one full run passes all **Must** cases.

### Cases

**iPad reporting and layout**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA2-01 | Must | Open Levels on the iPad. | iPad record created within 1 min, `type = ipad`, default name "iPad". Level matches the status bar rounded to 5 % (RPT-003 AC5). All four devices listed. |
| QA2-02 | Must | Plug the iPad into power with Levels in the background (Charger automation set, S4). | Within 2 min another device shows the iPad on power (RPT-003 AC4). Record minutes. |
| QA2-03 | Must | Regular width: check the grid. Then narrow the window (Slide Over or a small window). | Cards in UI-001 order; narrow width switches to the list without losing an open detail sheet (UI-005 R1, R3). |
| QA2-04 | Should | Open two Levels windows (iPadOS 26 windowing). Rename this iPad in one. | The other window updates; the new name reaches the Mac within 2 min (UI-005 AC5, R6). Only one report runs for the two windows (RPT-003 R2). |
| QA2-05 | Should | With a hardware keyboard: ⌘R, ⌘, and arrow keys. | Refresh runs once; Settings opens; arrows move between cards (UI-005 R4). |
| QA2-06 | Should | Old devices and Remove all my data on the iPad (UI-005 R5a). | Same results as QA1-54…QA1-55 on the iPhone. Don't run Remove all my data here unless the run is ending. |

**Watch reporting**

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA2-10 | Must | Open Levels on the watch. | Within 60 s the Mac or iPhone shows the watch level within 5 % of the watch's Control Center value (RPT-004 AC6). `type = watch`, default name "Apple Watch". |
| QA2-11 | Must | Put the iPhone in Airplane Mode; keep the watch on known Wi-Fi. Open the watch app. | The watch record still updates (direct CloudKit, ADR-0012; RPT-004 AC8). |
| QA2-12 | Must | Put the watch on its charger, open the app once, then close it. | The record shows the watch on power. A later stale "on power" record overnight is acceptable (RPT-004 edge cases). |
| QA2-13 | Should | Rename this watch in the watch app. | New name on the iPhone, iPad and Mac within 2 min (UI-006 R2). |

**Watch background refresh and complications** (complication on the daily face, S5; app not opened during the case)

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA2-20 | Must | Wear the watch normally for 2 hours without opening Levels. | The watch record's `updatedAt` advances at least once (RPT-004 AC7). Record each background refresh time from the log; expect up to ~2 an hour (ADR-0012). |
| QA2-21 | Must | Repeat QA2-20 over a full day (8 hours of wear). | Record the number of background reports and the longest gap between them. A measurement: any number is recorded; a gap over 2 h is noted as an issue to investigate, not a fail. |
| QA2-22 | Must | Unplug the Mac. Without opening the watch app, look at the complication every few minutes. | Record minutes until the complication shows the Mac not charging. The complication reads the cache only (UI-006, RPT-004 R8), so the change appears after a watch background refresh or push. |
| QA2-23 | Must | Leave the Mac asleep for 2 hours and look at the complication. | The Mac turns stale on the complication at the ADR-0017 threshold (65 min) without the app being opened (planned timeline entries). |
| QA2-24 | Should | Remove the complication from the face for 2 hours, then compare with QA2-20. | Record the difference in background reports. Documents why the complication matters (ADR-0012). |
| QA2-25 | Should | Check every watch widget family on a face that supports it, and the Smart Stack with a device ≤ 20 %. | Each family shows the right device and state (UI-006 R5); the low device ranks higher in the Smart Stack (UI-006 R7, best effort). |

**Sync across devices** (Mac, iPhone, iPad, Watch; record minutes, repeat 3 times)

| # | Pri | Steps | Expected |
|---|---|---|---|
| QA2-30 | Must | Plug in the iPad. Watch the Mac menu bar, the iPhone widget and the watch complication. | All three show the iPad on power. Record minutes per device. iPhone widget: same pass bar as QA1-20 (median ≤ 15 min, none > 60 min). Watch: recorded, no pass bar (watchOS controls timing). |
| QA2-31 | Must | Open the watch app at a new level. Watch the Mac, iPhone and iPad. | All three show the new watch level. Record minutes per device. |
| QA2-32 | Must | After QA2-30 and -31, compare the device lists on all four devices. | Same devices on every device, no duplicates, same names. Order follows UI-001 with each device's own row first. |
| QA2-33 | Should | Make 6 changes in 1 hour across devices (plug/unplug iPad and Mac every 10 min). | Count silent pushes received per device (logs). Writes stay within ADR-0008 limits. Feeds the NRB-001 decision (lead's call 2026-11-23: nearby mode only if measured delay justifies it). |
| QA2-34 | Must | Regression: re-run QA1-01, QA1-20 and QA1-60. | Same results as the QA-001 run. |

### Result table (copy per run)

| Run date | Tester | Devices + OS builds | Build type | Case | Result | Observed minutes (r1 / r2 / r3) | Notes |
|---|---|---|---|---|---|---|---|

## Design

No code. Uses the Diagnostics log from QA-001 on every device, including the watch (watch log entries for background refresh runs, pushes and reports, RPT-004 Tests).

## Edge cases and failure modes

- A watch in Low Power Mode gets little or no background time; note it when a watch case looks slow.
- A watch on the charger reports only when the app wakes; don't run QA2-20 or -21 while it charges.
- Results vary by time of day and how much the watch is used; three repeats is a minimum, not a statistic.
- Xcode attached to the watch or iPad changes background behaviour; run latency and refresh cases with the debugger detached.

## Acceptance criteria

- [ ] AC1 — Given the S1–S6 setup, when all **Must** cases are run, then each passes or has a linked issue that the owner accepts for v0.2.
- [ ] AC2 — Given QA2-20, QA2-21, QA2-22, QA2-30 and QA2-31, then observed minutes or counts are recorded for every repeat.
- [ ] AC3 — Given QA2-32, then all four devices show the same set of devices with no duplicates.
- [ ] AC4 — Given QA2-34, then the v0.1 regression cases pass.

## Tests

All cases are manual on real hardware: the watch background budget, complication reloads, watchOS push delivery and iPad multi-window behaviour can't be reproduced on the Simulator (ADR-0018). The logic behind them has Swift Testing unit tests in RPT-003, RPT-004, UI-005 and UI-006.

## Open questions

None.
