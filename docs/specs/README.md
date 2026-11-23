# Feature specs

How to write one: [ADR-0001](../adr/0001-record-architecture-decisions.md) and [template.md](template.md). Specs for v0.1–v0.2 move from Draft to Ready after review; v0.3 and later stay Outline until their milestone starts. Decisions are indexed in [../adr/README.md](../adr/README.md); terms are in [../glossary.md](../glossary.md); owner decisions and lead's calls are in [../decisions-log.md](../decisions-log.md).

## Now: Mac-first (free Personal Team)

Owner decision K (2026-11-23): no paid Apple Developer Program for now, so no iCloud and no push. Until the owner enrolls, the build order is:

1. SYNC-002 (done), the local-only `BatterySyncing` stand-in, MAC-002, UI-001.
2. UI-004 (menu-bar content; desktop widgets if the free team allows the App Group), MAC-001 without its iCloud and push parts.
3. MAC-003 (accessories), pulled forward from v0.3.

SPIKE-001, SYNC-001 and everything iPhone, iPad and Watch wait for enrollment. The v0.1 plan below is unchanged and resumes then.

## v0.1 — Mac agent and iPhone app with widgets

| ID | Title | Status | Depends on |
|---|---|---|---|
| [SPIKE-001](SPIKE-001-debug-build-push-check.md) | Debug-build silent push check (Production CloudKit container) | Draft | — |
| [SYNC-002](SYNC-002-device-model-and-cache.md) | Device battery model, CloudKit mapping and App Group cache | Draft | — |
| [SYNC-001](SYNC-001-cloudkit-sync-engine.md) | CloudKit sync service | Draft | SYNC-002 |
| [UI-001](UI-001-shared-device-list.md) | Shared device list components and store | Draft | SYNC-001, SYNC-002 |
| [RPT-001](RPT-001-iphone-battery-reporting.md) | iPhone battery reporting | Draft | SYNC-001, SYNC-002, UI-001 |
| [RPT-002](RPT-002-report-battery-app-intent.md) | "Report Battery" App Intent and Shortcuts automations | Draft | RPT-001, SYNC-001 |
| [MAC-002](MAC-002-mac-battery-reporter.md) | Mac battery reporter | Draft | SYNC-001, SYNC-002, UI-001 |
| [UI-003](UI-003-ios-widgets.md) | iPhone and iPad widgets (Home Screen, Lock Screen, StandBy) | Draft | UI-001, SYNC-002 |
| [UI-004](UI-004-mac-menu-bar-and-widgets.md) | Mac menu bar content and desktop widgets | Draft | UI-001, UI-003, SYNC-002 |
| [UI-002](UI-002-iphone-app.md) | iPhone app screens | Draft | UI-001, SYNC-001, SYNC-002, RPT-001, RPT-002 |
| [MAC-001](MAC-001-mac-menu-bar-agent.md) | Mac menu-bar agent | Draft | SYNC-001, SYNC-002, MAC-002, UI-004 |
| [QA-001](QA-001-real-device-test-plan.md) | v0.1 real-device test plan (Mac + iPhone) | Draft | SYNC-001, SYNC-002, RPT-001, RPT-002, MAC-001, MAC-002, UI-001, UI-002, UI-003, UI-004 |

## v0.2 — iPad and Apple Watch

| ID | Title | Status | Depends on |
|---|---|---|---|
| [RPT-003](RPT-003-ipad-battery-reporting.md) | iPad battery reporting | Draft | RPT-001, RPT-002 |
| [RPT-004](RPT-004-watch-battery-reporting.md) | Apple Watch battery reporting | Draft | RPT-001, SYNC-001, SYNC-002 |
| [UI-005](UI-005-ipad-app.md) | iPad app layout | Draft | UI-001, UI-002, UI-003 |
| [UI-006](UI-006-watch-app-and-complications.md) | Watch app and watch widgets (complications and Smart Stack) | Draft | UI-001, UI-003, SYNC-001, SYNC-002 |
| [QA-002](QA-002-v02-real-device-test-plan.md) | v0.2 real-device test plan (iPad + Apple Watch) | Draft | QA-001, RPT-003, RPT-004, UI-005, UI-006 |

## v0.3 and later (Outline)

| ID | Title | Milestone | Status | Depends on |
|---|---|---|---|---|
| [MAC-003](MAC-003-mac-accessory-reporting.md) | Mac accessory reporting | v0.3 | Outline | MAC-001, MAC-002, SYNC-001, SYNC-002 |
| [ALR-001](ALR-001-low-battery-alerts.md) | Low-battery alerts | v0.4 | Ready (Mac-first local; iCloud part Outline) | SYNC-002, MAC-001, MAC-003 |
| [HIS-001](HIS-001-history-and-charts.md) | 7-day history, charts and low-power-mode tracking (Mac, local only) | v0.5 | Ready | SYNC-002, MAC-002, MAC-003, UI-001, UI-004 |
| [NRB-001](NRB-001-ble-nearby-mode.md) | BLE nearby mode (Mac to iPhone without the cloud) | later | Outline | SYNC-001, MAC-001, RPT-001 |
| [FAM-001](FAM-001-family-sharing.md) | Family sharing | later | Outline | SYNC-001, SYNC-002 |

## Suggested build order

Derived from `depends_on`. Items in the same step have no dependency on each other and can be built in parallel.

**v0.1**

1. SPIKE-001 — 30-minute real-device check that a Debug iPhone build gets the silent push from the Production container. Its result decides whether the owner's daily iPhone build is an Xcode debug build or TestFlight (which moves Xcode Cloud to the start of v0.1, ADR-0018 §5). Owner decision 2026-11-23: first.
2. SYNC-002 — model types, charging flags, freshness, cache (everything else uses them).
3. SYNC-001 — sync service, `ReportReason`, `BatterySyncing`.
4. UI-001 — shared store, display preferences, row views.
5. RPT-001, MAC-002, UI-003 — iPhone reporter, Mac reporter, widget kit.
6. RPT-002, UI-004 — App Intent; Mac menu-bar content and desktop widgets.
7. UI-002, MAC-001 — iPhone app screens; Mac agent shell.
8. QA-001 — real-device run on a Mac laptop and an iPhone.

**v0.2** (all inputs come from v0.1)

1. RPT-003, RPT-004, UI-005, UI-006 — in parallel; RPT-004 before UI-006 if one person builds both, so the watch has its own record to show.
2. QA-002 — real-device run on the Mac, iPhone, iPad and Watch.
