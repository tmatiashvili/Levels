# ADR-0017: Widgets reload on data change only; age text updates itself; staleness is planned into the timeline

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0016, SYNC-001, SYNC-002, RPT-001…004, MAC-001, UI-001, UI-003, UI-004, UI-006

## Context

Facts from [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date):

- Each widget instance has its own 24-hour budget. "For a widget the user frequently views, a daily budget typically includes from 40 to 70 refreshes", roughly every 15–60 minutes.
- Reloads don't count against the budget while the containing app is in the foreground, when the widget performs an app intent, and for locale or accessibility changes. In StandBy the system refreshes at its own rate, outside the budget.
- Timeline entries should be at least about 5 minutes apart; WidgetKit may coalesce reloads.
- `WidgetCenter.shared.reloadAllTimelines()` / `reloadTimelines(ofKind:)` ask for a new timeline.

From [Displaying dynamic dates in widgets](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates): `Text(date, style: .relative)` keeps updating without reloads but shows seconds ("11 min, 14 sec"). [`SystemFormatStyle.DateReference`](https://developer.apple.com/documentation/swiftui/systemformatstyle/datereference) (`Text(.currentDate, format: .reference(to: date))`) gives natural phrasing ("5 minutes ago", "3 hours ago") and also updates live.

Levels' data changes when any device reports (SYNC-001 silent push → cache → reload). Reports are irregular: iPhone and iPad report on foreground, background refresh and Shortcuts automations at level thresholds (RPT); the Mac reports while awake (MAC-001); a sleeping Mac sends nothing. So "how old is this number" matters as much as the number.

## Decision

1. **Reload only when the snapshot changes.** Lead's call (2026-11-23): whenever a write changes the cached device list in any field (level, charging, low power, name, `updatedAt`, an added or removed device), from a fetch or from the device's own report, the writer calls `WidgetCenter.shared.reloadAllTimelines()`, coalesced to at most once per 60 s (SYNC-001 R8a). A newer `updatedAt` alone does trigger a reload, because it moves the device's stale moment (rule 3) and the age text's start. A write that leaves the list unchanged triggers nothing. Apps also reload when they move to the foreground (free).
2. **Age text never needs a reload.** Every widget shows the reading's age with `Text(.currentDate, format: .reference(to: updatedAt, allowedFields: [.minute, .hour, .day]))`. Fallback if that renders badly in a family: `Text(updatedAt, style: .relative)`.
3. **Staleness is planned in the timeline.** The provider computes, for each device shown, the moment it becomes stale. The timeline holds an entry for now plus one per future stale moment within 24 h (merged when closer than 5 min). Reload policy: `.atEnd` if there are future entries, else `.after(now + 6 h)` as a safety net.
4. **Two freshness states, per device type** (pure functions `FreshnessRule.of(_:at:)` and `FreshnessRule.staleDate(for:)` in `LevelsModel`, defined in SYNC-002):

   | Device | Stale when older than | Why |
   |---|---|---|
   | iPhone, iPad | 2 h | reports are irregular (background refresh, Shortcuts thresholds) |
   | Apple Watch | 2 h | same as iPhone |
   | Mac (with or without a battery) | 65 min | the agent writes a heartbeat every 30 min while awake (ADR-0008 W6, MAC-002 R6f); 65 min = one missed heartbeat plus slack; older means asleep, off or offline |
   | Accessory (v0.3) | 65 min | reported by the Mac agent, same heartbeat |
   | Mac or accessory actively charging: `isCharging == true` and `level < 100` | 30 min | level moves fast while charging, and the awake Mac agent writes every 5-point step (ADR-0008), so 30 min without a write means it stopped reporting |

   Lead's call (2026-11-23): the 30-minute charging rule applies **only to Macs and accessories**, because only they write on every 5-point change while awake. An iPhone, iPad or Watch keeps its normal 2 h threshold while charging: it writes only when the app runs (foreground, background refresh, Shortcuts, push), so a charging iPhone in a pocket would otherwise turn stale after 30 min while still charging normally. A Mac or accessory that is full on the charger (`isCharging == true` and `level == 100`) writes nothing while its level does not change, so it uses its type's normal 65 min threshold, not the charging one.

5. **What "stale" looks like:** the level and ring are dimmed (secondary style), a `clock` badge appears, the age text stays, VoiceOver adds "out of date". The last known level is always shown; it is never replaced by a dash. A stale charging device does not show the bolt (we no longer know).
6. **No data / no iCloud** (widgets read only the cache, so they can't tell exactly why it's empty):
   - Cache file missing or empty, and the app has never run → "Open Levels to start" (tap opens the app).
   - Cache has a `syncStatus` of `.signedOut` or `.restricted` (written by the app per SYNC-001/SYNC-002) → last known devices if any, plus `icloud.slash` and "iCloud off".
   - Cache present but only this device → that device plus "Other devices appear when they run Levels".
   SYNC-002's `SnapshotFile` carries `ownDeviceID`, `syncStatus` and `lastFetchAt` for these cases.

## Options considered

### Option A — reload on change + self-updating age text + planned stale entries (chosen)
- Pros: well inside 40–70 reloads/day for a handful of devices; age always correct; stale transition happens on time without spending budget.
- Cons: busy days (many devices reporting) can exhaust budget; then widgets lag until the app is opened.

### Option B — periodic timeline (`.after(15 min)`) reloads
- Pros: simple.
- Cons: spends the whole budget even when nothing changed; still late by up to the interval.

### Option C — WidgetKit push notifications
- Pros: server-driven widget reload.
- Cons: needs a server sending APNs, which conflicts with "no backend". Rejected.

## Consequences

- Positive: the "updated X ago" promise in the README holds without reloads.
- Negative / accepted risks: widget values can lag minutes behind the cache when the budget is tight; acceptable for battery levels. Because `updatedAt` changes reload too (rule 1), an awake Mac's 30-minute heartbeat alone asks for up to about 48 reloads a day; with other devices the requests can pass the 40–70 budget, and WidgetKit then drops some. The 60 s coalescing and the planned stale entries keep the shown ages correct anyway.
- Follow-ups: measure real reloads per day on the owner's phone during v0.1 (Xcode widget debugging or logs); tune thresholds in a later ADR if they feel wrong.

## References

- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Displaying dynamic dates in widgets](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates)
- [SystemFormatStyle.DateReference](https://developer.apple.com/documentation/swiftui/systemformatstyle/datereference)
- [Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
