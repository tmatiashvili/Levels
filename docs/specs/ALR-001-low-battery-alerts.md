---
id: ALR-001
title: Low-battery alerts
milestone: v0.4
status: Outline
depends_on: [SYNC-001, SYNC-002, RPT-001]
adrs: [4, 5, 6, 8, 11, 19]
targets: [Shared, Levels-iOS, Levels-Mac, Levels-Watch]
---

# ALR-001: Low-battery alerts

## Why

The point of Levels is to notice a low device before it matters: the MacBook in the bag, the iPad on the shelf. A glance at a widget only helps if you look. An alert on the device in your hand, once, when another device drops below its threshold, closes that gap.

## Scope

- In: one alert per device per discharge cycle when its level falls below that device's threshold; per-device thresholds (default 20%); on/off per device; alerts on iPhone, iPad, Mac, and on Watch through iPhone notification mirroring.
- Out: alerts for "fully charged" (maybe later); history-based predictions (HIS-001); family members' devices (FAM-001); accessories until v0.3 accessory reporting exists (then they use the same rules, with the Mac as reporter).

## Behaviour

- R1 — Each device has a threshold (5–50%, default 20%) and an on/off switch, set from any device. Owner decision (2026-11-23): alerts default on for Mac and iPad, off for iPhone and Watch (they already warn on-device).
- R2 — When a device's level falls below its threshold while not charging, every *other* signed-in device shows one visible notification: "<Device name> is at <level>%". Owner decision (2026-11-23): a device never alerts about itself; its subscription excludes its own events (predicate below) and the local fallback skips them too.
- R3 — No second alert for the same device until it has been charged (charging seen, or level back above threshold + 10 points). This is one "discharge cycle".
- R4 — An alert is delivered even if the receiving app was force-quit or hasn't run for hours.
- R5 — An alert that arrives late (the device is already charging, or the event is older than 1 hour) is not shown, where the receiving app gets the chance to check (see Design).

## Design

### Platform facts (verified)

- Silent pushes are low priority, not guaranteed, may be throttled ("don't try to send more than two or three per hour") and are dropped for a force-quit app. ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)) So "silent push → app posts a local notification" (the README idea) can miss alerts.
- `CKSubscription.NotificationInfo` can carry a visible alert: `alertBody`, `alertLocalizationKey` + `alertLocalizationArgs`, `title`, `subtitle`, `soundName`, `shouldBadge`, `category`, `shouldSendMutableContent`, `desiredKeys`. "If you don't set any of the `alertBody`, `soundName`, or `shouldBadge` properties, CloudKit sends the push notification using a lower priority and doesn't display any content." ([NotificationInfo](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class))
- `alertLocalizationArgs` are *record field names*; CloudKit fills in their values (strings, numbers or dates; strings over 100 characters may be cut). ([alertLocalizationArgs](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/alertlocalizationargs)) So the alert text can include the device name and level without the app running.
- `shouldSendContentAvailable` defaults to false. ([shouldSendContentAvailable](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/shouldsendcontentavailable))
- CloudKit query predicates support `<`, `>`, `==`, `AND`, `BEGINSWITH`, `IN` and more, on string, number, date and reference fields; they must be format-string predicates. ([CKQuery](https://developer.apple.com/documentation/cloudkit/ckquery)) So `level < 20` is a valid subscription predicate. The field must be queryable in the Production schema.
- A subscription "applies only to the user that creates it", and the server excludes the originating device "when appropriate". Query subscriptions work in the private database. ([CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription))

### Options

**Option A — Silent push, app decides and posts a local notification (README idea)**
- Pros: full control (dedupe, late-alert check, text); no extra records.
- Cons: misses alerts when pushes are throttled or the app was force-quit; on a busy day 2–3 pushes per hour can all be used by normal sync.

**Option B — Visible-alert `CKQuerySubscription` on `DeviceBattery` with `level < threshold`**
- Each device saves, for each other device, a subscription with `zoneID` = the `Levels` zone (ADR-0005), predicate `deviceId == %@ AND level < %@ AND isCharging == 0`, options `.firesOnRecordUpdate`, and a visible `NotificationInfo`.
- Pros: APNs delivers it as a normal alert; works with the app force-quit; no new record type.
- Cons: **Assumption:** it fires on *every* update while the record matches, so a device dropping 20 → 15 → 10 → 5 sends four alerts. There's no server-side dedupe. Thresholds change → every device must replace its subscriptions. Subscriptions grow as devices × devices.

**Option C — The reporting device writes a `LowBatteryEvent` record once per cycle; a visible-alert subscription fires on its creation (recommended)**
- The low device itself decides when it crossed the threshold (it knows its own history), and writes one `LowBatteryEvent` record: `deviceId`, `deviceName`, `level`, `createdAt`. Record name is deterministic, `low-<deviceId>-<cycleId>`, so a retry can't create a second event.
- Every device saves one `CKQuerySubscription` on `LowBatteryEvent` with `zoneID` set to the custom `Levels` zone (ADR-0005), predicate `deviceId != %@` (this device's ID, so a device never alerts about itself), options `.firesOnRecordCreation`, with `alertLocalizationKey` = "%1$@ is at %2$@%%" and `alertLocalizationArgs` = `["deviceName", "level"]`, `soundName` default, `shouldSendContentAvailable` false. Optionally `shouldSendMutableContent` true so a Notification Service Extension can drop late alerts (R5).
- Pros: exactly one push per cycle by construction; visible alert, so normal APNs priority; one subscription per device regardless of device count; thresholds live with the reporter, so changing one needs no subscription changes.
- Cons: only as timely as the low device's own reporting. An iPhone in a pocket reports only through Shortcuts automations and background refresh (ADR-0011), so it should have an automation near its threshold. One more record type (ADR-0005 must add it) and cleanup of old events.

Zone scope: event records live in the custom `Levels` zone like every other record. Apple's [zoneID](https://developer.apple.com/documentation/cloudkit/ckquerysubscription/zoneid) doc says the default is `nil` and that a query subscription is scoped to a zone only if `zoneID` is assigned explicitly; it does not say what `nil` matches in the private database (**Assumption:** only the default zone), so always set it. This alert subscription is in addition to ADR-0006's silent `CKDatabaseSubscription` for sync, which keeps working unchanged (and also fires, silently, when an event record is created).

**Recommendation:** Option C, with Option A kept as a fallback path: a device receiving a normal silent sync push that sees a fresh `LowBatteryEvent` not yet shown can post it locally (dedupe by event record name).

### Rest of the design (outline)

- Thresholds: stored per device; owned by ADR-0005 (a field on `DeviceBattery` or a small settings record). The reporter reads its own threshold.
- Cycle tracking in the reporter: `armed` when charging or level ≥ threshold + 10; when armed and level < threshold and not charging, write the event and disarm. State kept in the App Group (ADR-0009). Pure logic in `Shared`, unit-tested with Swift Testing (ADR-0018).
- Notification permission: ask with `UNUserNotificationCenter.requestAuthorization` when the user turns alerts on, not at first launch.
- watchOS: rely on iPhone notification mirroring first. **Assumption:** a CloudKit alert to the iPhone app mirrors to the Watch when the iPhone is locked, like other iPhone notifications.
- Cleanup: any device deletes `LowBatteryEvent` records older than 7 days when it runs.
- Mac: the agent registers for remote notifications and shows alerts through `UNUserNotificationCenter`; a menu-bar-only app can still post notifications. **Assumption:** to verify with ADR-0014's agent setup.

## Edge cases and failure modes

- Level jumps from 22% to 12% between reports: still one alert, with the reported level.
- Device charging when the event is created: not created (R2).
- Two writers for one device (reinstall with new ID): ADR-0007 decides; worst case two alerts.
- Low device offline (no network): event saved when it reconnects, probably late; R5 drops it if older than 1 hour (needs the service extension or a foreground check).
- iCloud signed out on the receiver: no alerts; nothing to do.
- Focus modes may hide the alert; use a `category` and consider Time Sensitive interruption level later (**Assumption:** CloudKit `NotificationInfo` has no interruption-level field; needs a service extension to set it).

## Acceptance criteria

- [ ] AC1 — Given Mac threshold 20% and alerts on, when the Mac discharges from 30% to 5%, then the iPhone shows exactly one alert naming the Mac.
- [ ] AC2 — Given the iPhone app was force-quit, when the Mac crosses its threshold, then the iPhone still shows the alert.
- [ ] AC3 — Given the Mac was charged to 50% after an alert, when it discharges below 20% again, then a second alert is shown.
- [ ] AC4 — Given cycle logic in `Shared`, when fed a scripted sequence of readings, then it emits one event per cycle (unit test).

## Tests

AC4 and the threshold/armed logic are Swift Testing unit tests with a fake `BatteryReader` and `CloudDatabase`. AC1–AC3 are manual real-device cases in a v0.4 QA spec, including a check of Option B's "fires on every update" assumption with a throwaway subscription in a separate test container (ADR-0018 §6), so the choice is based on observed behaviour.

## Open questions

- Closed. Owner decision (2026-11-23): a device never alerts about itself (R2); alerts default on for Mac and iPad, off for iPhone and Watch (R1).
