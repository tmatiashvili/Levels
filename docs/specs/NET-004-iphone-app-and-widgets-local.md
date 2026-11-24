---
id: NET-004
title: iPhone app and widgets in hub mode (free team)
milestone: free-team   # owner decision M
status: Ready
depends_on: [NET-002, NET-003, UI-001, UI-002, UI-003]
adrs: [3, 9, 16, 17, 19, 20]
targets: [Shared, Levels-iOS, Widgets-iOS]
---

# NET-004: iPhone app and widgets in hub mode (free team)

## Why

UI-002 and UI-003 assume iCloud: their empty states, banners, "Remove" and "About" text talk about iCloud. In hub mode (ADR-0020) the iPhone gets its data from the Mac on the home Wi-Fi. This spec lists only what changes. Everything not named here follows UI-002 and UI-003 as written.

## Scope

- In: first-run "Connect to your Mac"; pairing screens; hub banners; Settings ▸ Mac; changes to UI-002 R2, R8, R11, R12; widget empty states and the "Away" footer; the widget data variant (A or B, pending the free-team probe).
- Out (and where it goes instead): the pairing protocol → NET-002; sync behaviour → NET-003; the Mac side → NET-001. iPad (UI-005) reuses this later; not in scope now.

## Behaviour

### App (changes to UI-002)

- **R1** **Not paired.** Status `.notPaired` replaces the device list with a card: title "Connect to your Mac", text "Levels shows your Mac's battery and accessories when your iPhone is on the same Wi-Fi.", button **Connect**. This iPhone's own row shows below the card.
- **R2** **Connect** first shows one line: "Next, iOS asks to find devices on your network. Levels uses this only to reach your Mac." and **Continue**. Only then does the app start browsing (the system prompt appears on first use).
- **R3** **Pick and code.** The screen lists hubs in pairing mode ("Levels-ab12") and says "On your Mac, open Levels ▸ Settings ▸ iPhone ▸ Pair iPhone." With one hub it is pre-selected. A 6-digit field takes the code (number pad, one-time-code content type). Errors use NET-002 texts. After the code, the screen shows "Does your Mac show this number?", the confirmation number from `PairingSession.confirmationCode` (NET-002 R6a), and **Cancel** / **They match** (NET-002 R6b). They match calls `PairingSession.confirmLocally()` and the screen says "Now click They match on your Mac." until the Mac answers; Cancel calls `PairingSession.cancel()` and saves nothing. Cancel on the Mac shows "Pairing was cancelled on the Mac." Success: "Connected to <Mac name>" and the list appears.
- **R4** **Banners** (one at a time, UI-001 `SyncStatusBanner` style):

  | Status | Banner |
  |---|---|
  | `.awayFromHub(lastContactAt:)` | "Away from your Mac. Last update <age>." (age text self-updating, ADR-0017). Detail on tap: "Levels updates when this iPhone and your Mac are on the same Wi-Fi and the Mac is awake. A VPN can block it." |
  | `.restricted` | "Levels can't reach your Mac: Local Network access is off." + **Open Settings** |
  | `.misconfigured(401)` | "Your Mac no longer knows this iPhone." + **Pair again** |
  | `.misconfigured(426)` | "Update Levels on your Mac and iPhone." |
  | `.localOnly` | none |

  The iCloud banner of UI-001 R11 never shows in hub mode.
- **R5** **Pull to refresh** (UI-002 R2) is unchanged; it ends within 15 s. When away it ends after the 5 s search (NET-003 R5).
- **R6** **Live updates.** The app calls `startLiveUpdates()` when the scene becomes `.active` and `stopLiveUpdates()` when it leaves (NET-003 R7).
- **R7** **Settings ▸ Mac** (new section, top of UI-002 R8's sheet): the Mac's name, "Last update <age>", **Pair again**, and **Forget this Mac** (confirmation: "This iPhone stops getting levels from <name>."). Not paired: one row **Connect to your Mac**.
- **R8** **Old devices** (UI-002 R11): rows show, but Remove is replaced by the line "Remove old devices on your Mac." The Mac is the hub and its full snapshot would add them back (lead's call 26).
- **R9** **Remove all my data** (UI-002 R12), hub text: "This deletes the levels stored on this iPhone and this iPhone's battery on your Mac. Your Mac keeps its own levels." Confirming calls `removeAllData()` (NET-003 R10). Mac not reachable: alert "Connect to the same Wi-Fi as your Mac to remove data there. Nothing was deleted."
- **R10** **About** (UI-002 R8) says "Data stays on your devices and your home network. No analytics." in hub mode.
- **R11** `DeviceListStore.State` maps `.notPaired` → a new `.notPaired` state (R1), `.awayFromHub` → rows plus the away banner, `.restricted` and `.misconfigured` → rows plus their banner. `.onlyThisDevice` (UI-001 R11) when paired uses the footer "Your Mac's levels appear after it connects."

### Widgets (changes to UI-003)

- **R12** **Empty states** (UI-003 R8) in hub mode: never run → "Open Levels to start"; `.notPaired` → "Open Levels to connect your Mac"; only this device → this device plus (medium, large) "Your Mac appears when it connects". The "iCloud off" state is not used.
- **R13** **Away footer.** When the cache's `syncStatus` is `.awayFromHub`, `systemMedium` and `systemLarge` add one footer line "Away from Mac · <age of lastFetchAt>" (self-updating). Small and accessory families show nothing extra: row staleness (ADR-0017 rule 5) already tells the story.
- **R14** **Widget data, pending the free-team probe** (ADR-0020 Decision 7, lead's call 23). The builder implements the variant the probe allows, by this rule:
  - **Variant A — App Group cache (default).** The widget reads the cache only, as UI-003 says. The app reloads widgets by the SYNC-001 R8a rule after each ingest (free while in the foreground). The widget's data is as fresh as the app's last run.
  - **Variant B — the widget fetches from the Mac.** Used only if the probe shows all three: a widget extension can connect to the Mac with no prompt of its own and the app closed; it can read the pairing item from the shared Keychain group; a fetch finishes in under 4 s inside `getTimeline`. Then `getTimeline` calls `HubClient.snapshot(ifNoneMatch:wait: nil)` with a 4 s limit. On success it builds entries from the fetched devices merged with the cached own record, and writes the result to the cache if the App Group exists. On failure it uses the cache and marks the entry away. Reload policy: `.after(now + 15 min)` after a good fetch, `.after(now + 60 min)` after a failed one, with ADR-0017's stale entries before that. The widget links `LevelsNet`, never `LevelsSync` (ADR-0003). It never writes the outbox. Before the fetch, on the same connection, it posts this iPhone's own reading (its own `UIDevice` read) when the Mac needs it: the value changed, or the last reading the Mac accepted is 5 minutes old (`ReadingUploadPolicy`, shared with the app through the App Group; changed 2026-11-24, the widget's fetch is the iPhone's most regular contact with the Mac).
  - **Neither works** (no App Group and no widget network): the free-team build ships without the iPhone widget target. The app works alone.
  - The probe result and the chosen variant are recorded in this spec under AC9 and in the decisions log.
- **R15** Widget entitlements in hub mode: the App Group (variant A, and B when available) and the keychain access group (variant B). Variant B adds `NSBonjourServices` and `NSLocalNetworkUsageDescription` to the widget's Info.plist. **Assumption:** the extension's local network access follows the app's answer (the probe checks it).

## Design

- `LevelsApp` builds the hub composition (NET-003 R1) and a `HubSnapshotSource: DeviceSnapshotSource` that wraps `SnapshotCacheSource` and forwards refresh, rename, `removeAllData` and `resumeReporting` to `LocalNetworkSyncService`. `remove(_:)` throws `.notSupportedInHubMode` (R8 hides the button anyway).
- New views in `Levels-iOS`: `ConnectMacCard` (R1), `ConnectMacFlow` (R2, R3: permission explainer → hub list → code field), `MacSettingsSection` (R7). Banners reuse `SyncStatusBanner` with new cases.
- `LevelsUI`: `DeviceListStore.State` gains `.notPaired`; `SyncStatusBanner` gains `.awayFromHub(lastContactAt:)`, `.localNetworkOff`, `.hubForgotThisPhone`, `.updateNeeded`.
- `LevelsWidgetKit`: `DevicesProvider` takes an optional `fetch: (@Sendable () async -> [DeviceBattery]?)?`; `nil` = variant A. The widget target passes the `HubClient` call only in variant B. The provider stays unit-testable with a fake.
- Strings live in the app's string catalog; the R4 and R12 texts are the English source.
- **Builder's call:** whether the "Connect" card shows a small Mac illustration; layout of the code field.

## Edge cases and failure modes

- The owner denies Local Network: R4's `.restricted` banner; tapping Connect again explains and opens Settings (iOS won't prompt twice).
- Paired, but the Mac is off for a week: rows stay, stale, and move to "Old devices" after 30 days (UI-001 R14). The away banner stays.
- The free install expired and was reinstalled: pairing usually survives (NET-002); if not, R1 shows again.
- A widget picks a device in its configuration that the Mac later drops: UI-003's fallback ("Lowest battery") applies.
- Variant B widget on cellular: the fetch fails fast (no Bonjour result), the cache is used, policy 60 min.

## Acceptance criteria

- [ ] AC1 — Given status `.notPaired`, then the list shows the Connect card and this iPhone's row only (R1, R11).
- [ ] AC2 — Given Connect is tapped, then no browse starts before Continue is tapped (R2; unit test on the flow model).
- [ ] AC3 — Given each status in the R4 table, then the matching banner shows and no iCloud banner ever shows (R4; preview and unit test).
- [ ] AC4 — Given an old device in hub mode, then it shows under "Old devices" without Remove, with the "Remove old devices on your Mac" line (R8).
- [ ] AC5 — Given Remove all my data with the Mac unreachable, then the alert shows and the rows stay (R9).
- [ ] AC6 — Given the cache status `.awayFromHub` and `lastFetchAt` 2 h ago, then `systemMedium` shows "Away from Mac · 2 hours ago" and `systemSmall` shows no footer (R13; provider test plus preview).
- [ ] AC7 — Given `.notPaired`, then every widget family shows "Open Levels to connect your Mac" or its accessory equivalent (R12).
- [ ] AC8 — Variant B only: given a fake fetch that returns devices, then the timeline uses them and the policy is `.after(now + 15 min)`; given it fails, then the cache is used and the policy is `.after(now + 60 min)` (R14).
- [ ] AC9 — Probe result recorded: which variant was built and why (R14).
  - **Recorded 2026-11-24:** built **A + B** (lead's call 29). The probe showed App Group, widget networking and Bonjour work on the free team. The widget fetches when the cache is older than 15 min (`HubWidgetPlan`, `Widgets-iOS/WidgetHubFetch.swift`). Reading the shared-Keychain pairing from the widget is not yet verified on hardware (needs a paired iPhone); when the widget can't read it, it falls back to A by itself (`FetchResult.unavailable`, logged in category `widget`).
- [ ] AC10 — On real hardware: pair, then close the app; plug in the Mac. Variant A: the widget updates the next time the app runs. Variant B: the widget updates within its next reload (record the delay; target under 30 min).
- [ ] AC11 — On real hardware: VoiceOver reads the away banner and the Connect card in a sensible order.

## Tests

- Unit (Swift Testing): store state mapping (AC1, AC3), flow model (AC2), provider with and without `fetch` (AC6–AC8).
- Previews: every banner; Connect card; Settings ▸ Mac; widgets in away and not-paired states, all rendering modes (UI-003 R9).
- Real hardware: AC10, AC11, and a Local Network deny-then-allow pass.

## Open questions

None for the owner. The widget variant waits on the free-team probe, not on a decision.
