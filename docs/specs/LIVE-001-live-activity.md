---
id: LIVE-001
title: Live levels Live Activity (iPhone, Mac, AirPods)
milestone: free-team   # owner decision V: built now; local updates work today, push after enrollment
status: Draft
depends_on: [NET-003, NET-004, UI-003, PUSH-001]
adrs: [17, 20, 21, 23]
targets: [Shared, Levels-iOS, Widgets-iOS, Levels-Mac, relay]
---

# LIVE-001: Live levels Live Activity (iPhone, Mac, AirPods)

## Why

The owner wants to see the current battery of this iPhone, the Mac and the AirPods on the iPhone without opening the app. Widgets can't do it: iOS gives them about 40–70 reloads a day (ADR-0017, ADR-0023). A Live Activity can show live data on the Lock Screen, in StandBy and in the Dynamic Island. This spec replaces PUSH-001's one-device "Follow charging" activity (R74) with one activity that shows all three.

## Scope

- In: the ActivityKit attributes and content-state; the Lock Screen, StandBy and Dynamic Island (compact, minimal, expanded) views in `Widgets-iOS`; Start and Stop in the app; the end rules; local updates without a paid account; Mac pushes through the relay once push is on (PUSH-001); tests.
- Out (and where it goes instead): whether it is Free or Pro → open question 1 (gate in one function today); push-to-start (needs an alert, ADR-0023 Decision 2) → not planned; Watch and CarPlay layouts beyond the system's own Smart Stack rendering → later; more than three devices → later.

## Behaviour

### Start and stop

- **R1** The Devices screen has a pin button in the toolbar: "Pin levels to Lock Screen" starts the activity, "Unpin from Lock Screen" ends it. Settings has a "Lock Screen" section with the toggle "Show levels on Lock Screen" and a footer that says how fresh it is (R40).
- **R2** Every start goes through `LiveActivityAccess.isAllowed()` (Levels-iOS). It returns `true` until open question 1 is decided; the TODO there points at `ProGate` (MON-001 R19).
- **R3** Start is refused (and says why) when `isAllowed()` is false, Live Activities are off for Levels in Settings, sample devices are on (DEMO-001), or no Mac is paired. The controls are hidden while sample devices are on or no Mac is paired.
- **R4** Both controls show the same state: an activity of ours is running or not.
- **R5** One activity at a time. Start ends any other Levels activity first. At launch the app adopts the activity iOS still shows and ends any extra one.
- **R6** Stop ends the activity at once (`dismissalPolicy: .immediate`). A swipe on the Lock Screen ends it too; the app notices (`activityStateUpdates`) and its controls flip back.
- **R7** iOS ends an activity after 8 hours. The app also ends it itself when it runs after 8 hours (launch, foreground, a background refresh, a cache change).
- **R8** "Forget this Mac" ends it. So does any refresh that finds no paired Mac.

### Content

- **R10** Content-state `LiveLevelsState` (LevelsModel): `{"devices":[{"role":"iphone"|"mac"|"airpods","level":0…100 (absent = unknown),"charging":Bool,"updatedAt":<Unix s>}]}`. Fixed order iPhone, Mac, AirPods; at most one per role; a role with no device is left out. Default JSON coding (Apple decodes pushes with the default strategies); `updatedAt` is an integer, not a `Date`. No names.
- **R11** The content-state stays far under the 4 KB APNs and ActivityKit limit: under 512 bytes for three devices.
- **R12** Static attributes `LevelsLiveActivityAttributes` (LevelsWidgetKit, iOS only): the names as the iPhone shows them (`LiveLevelsNames`) and `startedAt` (Unix s). Set at start, never pushed.
- **R13** Which devices: the iPhone is this iPhone's own record; the Mac is the paired Mac's record (`HubPairing.hubDeviceID`), else the Mac with the newest reading; AirPods are one AirPods group, the one reported by that Mac first, else the newest; its level is the lower of the two buds, the case only when no bud has a level. "Charging" means charging or plugged in. The iPhone and the Mac use the same function (`LiveLevels.state`).

### Views

- **R14** Lock Screen and StandBy: one column per device (ring with the device symbol, percentage, short name), then "Updated 14:05". When the stale date has passed: dimmed rings and "Not updated since 14:05". Times are clock times, not live timers.
- **R15** Dynamic Island compact: the Mac on the leading side and the AirPods on the trailing side (the iPhone when one is missing; iOS shows the iPhone's own battery in the status bar), symbol and percentage. Minimal: one small ring for the lowest device that isn't charging, else the lowest. Expanded: iPhone, Mac and AirPods columns, footer below.
- **R16** Colours follow `RingStyle` (ADR-0016 rule 3): green while charging, red at or below the alert threshold (20 %), primary otherwise. A stale device never shows as charging. A tap opens the app (`levels://`).

### Updates without a paid account (works today)

- **R20** The app updates the activity on every cache change while its process runs: the long-poll to the Mac while the app is open (NET-003 R7), this iPhone's own battery events (RPT-001 R5), a background refresh (RPT-001 R7), and a Shortcuts "Report Battery" run (RPT-002). It reads the App Group snapshot and lays this iPhone's live `UIDevice` reading over its own record.
- **R21** It updates on a visible change (a whole percent, charging, a device appearing or leaving), and on newer data at most once a minute, so the stale date moves on. While an activity runs, a "Report Battery" run also asks the Mac for its levels (at most 5 s) before it updates. A background refresh updates it before iOS suspends the app. Per device, the app keeps whichever reading is newer, the one the activity shows (perhaps pushed by the Mac) or its own (`LiveLevels.newest`), so a local update never takes back a newer pushed level.
- **R22** Every update sets `staleDate` = now + 30 minutes.

### Updates with push (after enrollment, `LEVELS_PUSH_ENABLED = YES`)

- **R23** The Mac pushes priority 10, at once, when a shown device is plugged in or unplugged, reaches 100 %, or crosses the alert threshold.
- **R24** Other visible changes are pushed with priority 5, at most one per 60 s; changes inside the gap are coalesced into one push at its end. A newer reading with the same picture is not pushed.
- **R25** At most 10 priority-10 pushes per activity per hour (the relay allows 12, PUSH-001 R41); over that, urgent changes go as priority 5 after the gap.
- **R26** No push while that iPhone's app is in the foreground (its long-poll is open, PUSH-001 R54): the app updates the activity itself, and what it shows counts as pushed.
- **R27** The Mac pushes a token for at most 8 hours after it first saw it. A new token (a new activity) starts over.
- **R28** Every push: `event: update`, `timestamp` = now, `stale-date` = now + 30 min, the content-state of R10 built for that iPhone. Never `start`, never an alert.
- **R29** Gone tokens (410, `invalidTokens`) are dropped and the iPhone is asked for a new grant; a refused grant stops pushes until a new one arrives; 429 and 5xx back off (PUSH-001 R16, R19).
- **R30** Wire format: `POST /v1/widget-push` with `{"tokens":[{"token","env","kind":"liveActivity"}],"payload":{"content-state":…,"event":"update","priority":5|10,"stale-date":…,"timestamp":…}}`, exactly PUSH-001 R10. No new fields; the shared vector `relay/test/vectors/live-activity-v1.json` pins the bytes.
- **R31** The app starts the activity with `pushType: .token` in push builds (none in free builds). Each `pushTokenUpdates` token goes to the App Group (`push.liveActivityToken`); the next token upload to the Mac (`PUT /v1/push-tokens` v2) carries it next to the widget's token, under one relay grant that covers both kinds. The upload follows within one long-poll (25 s) or at once through a refresh. The token is cleared when the activity ends, so the next upload drops it.

### Honesty

- **R40** The Settings footer says it updates live while Levels is open and only now and then while Levels is closed (free build), or that the Mac sends new levels as they change (push build). The footer line on the activity always shows when the levels were read.

## Design

- `LevelsModel/LiveLevels.swift`: `LiveLevelsState`, `LiveLevels.state(from:iphoneID:macID:)`, `LiveLevelsPolicy` (visible change, urgency, start blockers, end reasons, local update rule). Pure; no ActivityKit, so the Mac builds the same state.
- `LevelsWidgetKit/LiveLevelsAttributes.swift` (`#if os(iOS)`): `LevelsLiveActivityAttributes: ActivityAttributes` with `ContentState = LiveLevelsState`. One type for the app and the extension.
- `LevelsWidgetKit/LiveLevelsViews.swift`: `LiveLevelsNames`, `LiveLevelsDisplay` (pure rules), `LiveLevelRing`, `LiveLevelColumn`, `LiveLevelsFooter`, `LiveLevelsLockScreenView`, `LiveLevelsCompactView`, `LiveLevelsMinimalView`.
- `Widgets-iOS/LevelsLiveActivity.swift`: the `ActivityConfiguration`, in the widget bundle.
- `Levels-iOS/LiveActivity/`: `LiveActivityAccess` (R2), `LiveActivityController` (@MainActor; start, stop, restore, refresh, token), `LiveActivityControls` (R1), `AppModel+LiveActivity` (R21 intent path). AppModel calls the controller on cache changes, launch, foreground, background refresh and Forget.
- `LevelsNet/PushRelay.swift`: `LiveActivityPushPayload`, `LiveActivityRelayBody`, `PushRelayClient.sendLiveActivity`.
- `LevelsSync/LiveActivityPushScheduler.swift`: the Mac's R23–R29, fed by the same `PushFeed` as `WidgetPushScheduler`.
- Info.plist (Levels-iOS): `NSSupportsLiveActivities = YES`, `NSSupportsLiveActivitiesFrequentUpdates = YES`. No entitlement: local Live Activities work on a free Personal Team; push needs `aps-environment`, which only the push entitlements file has.
- **Builder's call:** the 60 s minimum gap for local "newer data" updates (R21), the cap of 10 urgent pushes per hour (R25), and the pin metaphor for the toolbar button.

## Edge cases and failure modes

- App killed by the user: no local updates; the activity goes stale after 30 minutes and iOS ends it at 8 hours. With push the Mac keeps it current.
- Mac asleep or off the Wi-Fi: the Mac and AirPods values stop changing; the footer time shows their age; stale after 30 minutes.
- Live Activities turned off in Settings while one runs: iOS ends it; the app's controls flip back (R6).
- Free build pressing Start without push: works (no `pushType`); no token is ever asked for.
- Pushes after the user ended the activity: the token is cleared on the iPhone and dropped at the next upload; until then the Mac's pushes go nowhere and the 8-hour cap (R27) bounds them.

## Acceptance criteria

Automated:

- [x] AC1 — Given a device list with two Macs, three AirPods records and this iPhone, `LiveLevels.state` picks this iPhone, the paired Mac and the lower bud, in R10 order (`LiveLevelsStateTests`).
- [x] AC2 — The content-state encodes with default strategies to the exact R10 JSON, decodes back with a default decoder, and the largest one is under 512 bytes inside an APNs body under 4 KB (`LiveLevelsStateTests`).
- [x] AC3 — The newer reading per device wins over a pushed one (`LiveLevelsStateTests`). Visible change, urgency (plug, unplug, 100 %, threshold), start blockers, 8-hour and unpaired end, and the local update rule (`LiveLevelsPolicyTests`).
- [x] AC4 — Mac: first push is priority 5 with the R28 fields and only the Live Activity token; steps inside 60 s coalesce into one push of the newest state; an unchanged picture isn't pushed; plug and unplug go at once as priority 10; the urgent cap falls back to priority 5 (`LiveActivityPushSchedulerTests`).
- [x] AC5 — Mac: nothing while the app is in the foreground and that picture counts as pushed; nothing 8 hours after the token appeared; a new token starts over; nothing without a grant or a Live Activity token (`LiveActivityPushSchedulerTests`).
- [x] AC6 — Mac: 410 drops the token and asks for a grant; a refused grant stops pushes; 429 holds until `Retry-After` (`LiveActivityPushSchedulerTests`).
- [x] AC7 — Display rules: compact sides, minimal device, ring colours, names (`LiveLevelsDisplayTests`).
- [x] AC8 — The free build (`LEVELS_PUSH_ENABLED = NO`) builds and signs with team N5P82JNFSC with no push entitlement; the push build compiles (`LEVELS_PUSH_ENABLED = YES`, unsigned).
- [x] AC9 — Shared vector: the Mac encodes exactly the vector body, the relay parses it and builds the vector's APNs body with `apns-push-type: liveactivity` and the vector's priority, and the iPhone decodes that body's content-state (`LiveActivityVectorTests`, `relay/test/live-activity-vector.test.ts`).

Manual, free build, real iPhone:

- [ ] AC10 — Pin from the Devices screen: the Lock Screen and the Dynamic Island show iPhone, Mac and AirPods; Unpin and a Lock Screen swipe end it and the controls flip back.
- [ ] AC11 — With the app open, unplugging the Mac shows on the Lock Screen within a few seconds (long-poll).
- [ ] AC12 — With the app closed, a "Report Battery" automation run updates the iPhone level and, on the home Wi-Fi, the Mac's.
- [ ] AC13 — Forget this Mac ends the activity; after 8 hours it is gone.

Manual, after enrollment:

- [ ] AC14 — With the app closed, a Mac level change reaches the Lock Screen within 2 minutes; unplugging within seconds (priority 10). `wrangler tail` shows no token or payload (PUSH-001 AC15).

## Tests

AC1–AC7 and AC9 are Swift Testing tests in `Shared` (`swift test`) and one vitest file in `relay/` (`npm test`). AC8 is an `xcodebuild` of `Levels-iOS` and `Levels-Mac`. AC10–AC14 need a real iPhone (Live Activities don't run in unit tests) and, for AC14, the paid account.

## Open questions

1. Is the Live Activity Free or Pro? PUSH-001 R75 and its open question 1 recommend Pro. The gate is one function, `LiveActivityAccess.isAllowed()`, returning `true` until decided.
