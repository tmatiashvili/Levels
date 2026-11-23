# Feature specs

How to write one: [ADR-0001](../adr/0001-record-architecture-decisions.md) and [template.md](template.md). Specs for v0.1–v0.2 move from Draft to Ready after review; v0.3 and later stay Outline until their milestone starts. Decisions are indexed in [../adr/README.md](../adr/README.md); terms are in [../glossary.md](../glossary.md); owner decisions and lead's calls are in [../decisions-log.md](../decisions-log.md).

## Now: free Personal Team (Mac-first, then the Mac hub)

Owner decision K (2026-11-23): no paid Apple Developer Program for now, so no iCloud and no push. Until the owner enrolls, the build order is:

1. SYNC-002 (done), the local-only `BatterySyncing` stand-in, MAC-002, UI-001.
2. UI-004 (menu-bar content; desktop widgets if the free team allows the App Group), MAC-001 without its iCloud and push parts.
3. MAC-003 (accessories), pulled forward from v0.3.

Owner decision M (2026-11-24): still no paid program, but the iPhone works now through the **Mac as a hub on the home Wi-Fi** ([ADR-0020](../adr/0020-local-network-hub-sync.md)). The Mac serves the levels it holds; the iPhone app and widget read them, and the iPhone sends its own battery to the Mac. Same network only; the free iPhone install expires every 7 days. Then:

4. NET-001 (Mac hub server). Its first step is the TLS-PSK check (NET-001 AC1).
5. NET-002 (pairing), and RPT-001's iPhone reader and triggers without the push parts (in parallel).
6. NET-003 (iPhone hub client), then NET-004 (iPhone app and widgets in hub mode) together with the UI-002 and UI-003 parts it names. NET-004's widget variant waits on the free-team probe (`feature/ios-free-probe`).
7. A real-device pass with the owner's Mac and iPhone (NET-001…NET-004 hardware ACs).

SPIKE-001, SYNC-001, RPT-002's iCloud parts, iPad and Watch still wait for enrollment. The v0.1 plan below is unchanged and resumes then; at that point CloudKit replaces the hub (ADR-0020 Decision 12).

| ID | Title | Status | Depends on |
|---|---|---|---|
| [NET-001](NET-001-mac-hub-server.md) | Mac hub server on the home network | Ready | SYNC-002, MAC-001, MAC-002 |
| [NET-002](NET-002-pairing.md) | Pairing an iPhone with the Mac hub | Ready | NET-001 |
| [NET-003](NET-003-iphone-hub-client.md) | iPhone hub client and reporting to the Mac | Ready | NET-001, NET-002, SYNC-002, UI-001 |
| [NET-004](NET-004-iphone-app-and-widgets-local.md) | iPhone app and widgets in hub mode (free team) | Ready | NET-002, NET-003, UI-001, UI-002, UI-003 |

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
| [ALR-001](ALR-001-low-battery-alerts.md) | Low-battery alerts | v0.4 | Outline | SYNC-001, SYNC-002, RPT-001 |
| [HIS-001](HIS-001-history-and-charts.md) | 7-day history, charts and low-power-mode tracking | v0.5 | Outline | SYNC-001, SYNC-002, RPT-001, UI-001 |
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
