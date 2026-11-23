---
id: ALR-001
title: Low-battery alerts
milestone: v0.4
status: Ready
depends_on: [SYNC-002, MAC-001, MAC-003]
adrs: [3, 9, 14, 15, 18, 19]
targets: [Shared, Levels-Mac]
---

# ALR-001: Low-battery alerts

## Why

The point of Levels is to notice a low device before it matters: the AirPods before a call, the Magic Keyboard before it dies mid-sentence. A glance at the menu bar only helps if you look. One notification, once, when an accessory drops below its threshold, closes that gap.

This spec is build-ready for the **Mac-first, local-only build** (owner decision K): the Mac alerts about the accessories it reports itself. The iCloud design, where every device alerts about the others through CloudKit, is kept below under "Later: iCloud alerts" and stays Outline until the owner enrolls in the paid program.

## Scope

- In (this build): local notifications on the Mac about its own connected accessories (MAC-003: AirPods and Beats, Magic Mouse, Keyboard, Trackpad, other HID batteries); one alert per accessory per discharge cycle; one threshold for all accessories; on/off for alerts and per device; notification permission asked when it is first needed; tap opens the device.
- Out (this build): alerts about the Mac's own battery (macOS already warns); alerts on iPhone, iPad and Watch, and alerts about them (need iCloud, see "Later: iCloud alerts"); per-device thresholds (later, with the iCloud design); "fully charged" alerts; history-based predictions (HIS-001); family devices (FAM-001); quiet hours (not in this spec: macOS Focus already covers it).

## Behaviour

- **R1 — Defaults.** Owner decision H: alerts default **on** for Mac and iPad, off for iPhone and Watch (`AlertSettings.defaultEnabled(for:)`). On this Mac build the master switch "Low-battery alerts" is on until the user turns it off. Settings are local to the Mac (App Group `UserDefaults`, key `alertSettings`), never synced.
- **R2 — Who alerts about whom.** Owner decision H: a device never alerts about itself. The Mac alerts about every battery in its snapshot except its own record (`ownDeviceID`); in this build that means its accessories only. Hidden devices (UI-001 R2) do not alert.
- **R3 — Alert subjects (lead's call 18a).** A Magic device or other single-battery accessory is one subject. AirPods and other grouped accessories (MAC-003 R3a) are **two** subjects: the **earbuds** (left and right together, level = the lower bud, charging = that bud's charging) and the **case**. Not one per component, so a pair of buds draining together gives one alert, not two; not one per group, so a low case is not hidden by full buds (and is named as the case).
- **R4 — Threshold.** One threshold for all subjects, 5–50% in steps of 5, default 20% (same as UI-001 R7's red). A subject is low when `level ≤ threshold` and it is not charging. Readings with no level never alert.
- **R5 — One alert per discharge cycle (hysteresis).** Each subject is *armed* (may alert) or *disarmed*. An armed subject that is low posts one notification and becomes disarmed. A disarmed subject re-arms when it is seen charging, or its level is at or above `threshold + 10`. Unknown subjects start armed. State persists across relaunches (App Group `UserDefaults`, key `alertState`), so a relaunch never repeats an alert. Re-arming is tracked even while alerts or that device are switched off; only posting needs them on.
- **R6 — Late readings.** A reading older than 1 hour (`readingDate`, SYNC-002 R8) is ignored: it neither alerts nor changes state. This keeps a disconnected accessory's last cached level from alerting at launch.
- **R7 — Per-device switch.** Settings lists each accessory row (UI-001 R13 rows, so AirPods are one row covering earbuds and case) with a switch, default on. Off: that device's subjects never post. Stored as the set of switched-off row IDs (record ID, or the group ID for AirPods).
- **R8 — Notification text.** Plain and short, body only, the app name is the header macOS shows: "<Name> is at <level>%" (e.g. "Magic Mouse is at 15%"); for the earbuds "<Name> is at <level>%" with the headset name; for the case "<Name> case is at <level>%". Default sound. Identifier `low-<subject key>`, so a new alert for the same subject replaces the old one in Notification Center.
- **R9 — Tap.** Tapping the notification opens `levels://device/<uuid>` with the row's ID (the group ID for AirPods), which opens the device window with that row highlighted (UI-004 R14).
- **R10 — Permission (lead's call 18b).** Levels never asks at launch. It calls `UNUserNotificationCenter.requestAuthorization([.alert, .sound])` the first time it is needed: when the user turns "Low-battery alerts" on in Settings, or, because the default is on (R1), when the first alert is due and macOS has not been asked yet; that alert is posted if the user allows. If notifications are denied, nothing is posted and Settings shows "Notifications for Levels are off in System Settings." with an "Open Notification Settings" button. The status is re-read whenever Settings appears.
- **R11 — Reporting off.** While reporting is off (Remove all my data, SYNC-001 R15a) no alerts are posted and the alert state is cleared; Settings says "Alerts pause while reporting is off."
- **R12 — Feeding.** Alerts are evaluated on every snapshot change signal (each report, refresh and cache write), on launch, and when an alert setting changes. Turning alerts on with an accessory already low alerts once for it.

## Design

### Shared (`LevelsModel`, Foundation only — ADR-0003 allows it: value types and pure rules)

`Shared/Sources/LevelsModel/LowBatteryAlerts.swift`:

```swift
public struct AlertSettings: Codable, Sendable, Equatable {
    public static let thresholdRange = 5...50, thresholdStep = 5, defaultThreshold = 20, rearmMargin = 10
    public var isEnabled: Bool            // R1
    public var threshold: Int             // R4, clamped and rounded to the step
    public var mutedDevices: Set<DeviceID> // R7: row IDs
    public static func defaultEnabled(for kind: DeviceKind) -> Bool  // H: mac, ipad → true
    public init(isEnabled: Bool, threshold: Int = 20, mutedDevices: Set<DeviceID> = [])
    public static func defaults(for kind: DeviceKind) -> AlertSettings
}
public struct AlertState: Codable, Sendable, Equatable { public var disarmed: Set<String> }  // R5
public struct AlertSubject: Sendable, Equatable { key, rowID, name, part (.whole/.earbuds/.case), level, isCharging, readingDate }
public struct LowBatteryAlert: Sendable, Equatable { subjectKey, rowID, name, part, level; var text; var identifier; var url }
public enum LowBatteryAlertRule {
    public static func subjects(in snapshot: SnapshotFile, hidden: Set<DeviceID>, now: Date) -> [AlertSubject]   // R2, R3
    public static func evaluate(_ subjects: [AlertSubject], settings: AlertSettings, state: AlertState,
                                reportingEnabled: Bool, now: Date) -> (alerts: [LowBatteryAlert], state: AlertState)  // R4–R7, R11
}
public protocol AlertStore: Sendable { loadSettings/saveSettings/loadState/saveState }
public struct UserDefaultsAlertStore: AlertStore  // keys alertSettings, alertState
public final class InMemoryAlertStore: AlertStore
```

Subject keys: `<recordName>` for a whole device, `<groupID>:earbuds` and `<groupID>:case` for grouped accessories. Hidden: a subject is dropped when its row ID or any of its records is hidden (same rule as UI-001 R2).

### Mac (`Levels-Mac`)

- `LowBatteryAlerts.swift`: `@MainActor @Observable final class AlertController` holds `settings` and the notification `authorization` (`.notDetermined/.allowed/.denied`), listens to the snapshot source's `changes()`, runs the rule, saves state, posts with `UNUserNotificationCenter.add` (trigger `nil`). A `NotificationDelegate` (set in `init`, before launch finishes, so a tap that launches the app is delivered) shows banners while the agent is frontmost and opens the URL on tap with `NSWorkspace.open`, which the app's own `levels://` handler receives (MAC-001 R2a).
- `MacAppModel` creates the controller and starts it in `start()`. `MacSettingsView` gets an "Alerts" section: master switch, "Alert at" picker (5–50%), per-device switches, denied and reporting-off notes.
- No entitlement or Info.plist key: local notifications need none on an unsandboxed agent (lead's call 16). **Assumption:** an `LSUIElement` agent gets banners like a regular app; checked by AC10.

## Edge cases and failure modes

- Level jumps from 22% to 12% between scans: one alert, with the reported level.
- Accessory charging when low: no alert; charging re-arms.
- AirPods: buds in the case charge (re-arm earbuds); the case on its own discharges and alerts as "case".
- One bud only connected: earbuds use that bud.
- Accessory disconnects and reconnects hours later at a lower level: the new reading is fresh, so it alerts if armed.
- Threshold raised above a disarmed subject's level: stays disarmed until it charges or reaches the new threshold + 10.
- Device removed from the list: its state is pruned on the next evaluation.
- Notifications denied, or Focus on: macOS drops or hides them; Levels does not retry. State still disarms, so a later allow does not flood old alerts.
- App Group unavailable: `UserDefaults.standard` (same fallback as display preferences).

## Acceptance criteria

- [ ] AC1 — Given threshold 20% and alerts on, when an accessory discharges 30 → 25 → 19 → 15 → 5 without charging, then exactly one alert is emitted, at 19% (R4, R5).
- [ ] AC2 — Given an alert was emitted, when the accessory is seen charging (or reaches 30%) and then discharges below 20% again, then a second alert is emitted; reaching only 25% does not re-arm (R5).
- [ ] AC3 — Given a snapshot with this Mac's own record at 5%, then no alert is about the Mac (R2); given a hidden accessory at 5%, no alert.
- [ ] AC4 — Given AirPods left 15%, right 18%, case 60%, then one earbuds alert at 15% and no case alert; given the case at 10% too, a separate case alert "… case is at 10%" (R3, R8).
- [ ] AC5 — Given alerts off, or that device switched off, then no alert; a charge seen meanwhile still re-arms (R5, R7).
- [ ] AC6 — Given reporting off, then no alerts and the state is empty (R11).
- [ ] AC7 — Given a reading older than 1 hour at 5%, then no alert and no state change (R6).
- [ ] AC8 — Given state saved after an alert, when evaluated again from the loaded state (relaunch), then no second alert (R5).
- [ ] AC9 — Defaults: Mac and iPad on, iPhone and Watch off, threshold 20; thresholds outside 5–50 or off-step are clamped and rounded (R1, R4). Alert text and identifier and URL as in R8, R9.
- [ ] AC10 — Manual: launch the Debug build with no low accessory: no permission prompt. Turn alerts off and on in Settings: macOS asks once. Deny: Settings shows the denied note. Allow, and a low accessory shows a banner; tapping it opens the device window with the row highlighted.

## Tests

AC1–AC9 are Swift Testing unit tests in `LevelsModelTests/LowBatteryAlertTests.swift` against the pure rule and `InMemoryAlertStore` / `UserDefaultsAlertStore` (ADR-0018). AC10 is manual on the Mac (the notification center and its prompt can't run under `swift test`).

## Open questions

- Closed. Owner decision H: a device never alerts about itself; defaults on for Mac and iPad, off for iPhone and Watch (R1, R2). Builder-level choices are lead's call 18 (subjects, permission timing, single threshold, quiet hours left to Focus).

## Later: iCloud alerts (Outline, not built)

Kept from the earlier design for when CloudKit sync exists (owner decision K lifts). There, every signed-in device alerts about the *other* devices, per-device thresholds are set from any device, and the low device writes one `LowBatteryEvent` per cycle that a visible-alert `CKQuerySubscription` delivers even to a force-quit app. The local rule above (subjects, hysteresis, late-reading check, defaults) stays the same; only the transport and the threshold storage change. Rules carried over from the earlier outline:

- C-R1 — Each device has a threshold (5–50%, default 20%) and an on/off switch, set from any device.
- C-R2 — When a device's level falls below its threshold while not charging, every *other* signed-in device shows one visible notification: "<Device name> is at <level>%". Its subscription excludes its own events and the local fallback skips them too.
- C-R3 — No second alert for the same device until it has been charged (charging seen, or level back above threshold + 10 points).
- C-R4 — An alert is delivered even if the receiving app was force-quit or hasn't run for hours.
- C-R5 — An alert that arrives late (the device is already charging, or the event is older than 1 hour) is not shown, where the receiving app gets the chance to check.

#### Platform facts (verified)

- Silent pushes are low priority, not guaranteed, may be throttled ("don't try to send more than two or three per hour") and are dropped for a force-quit app. ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)) So "silent push → app posts a local notification" (the README idea) can miss alerts.
- `CKSubscription.NotificationInfo` can carry a visible alert: `alertBody`, `alertLocalizationKey` + `alertLocalizationArgs`, `title`, `subtitle`, `soundName`, `shouldBadge`, `category`, `shouldSendMutableContent`, `desiredKeys`. "If you don't set any of the `alertBody`, `soundName`, or `shouldBadge` properties, CloudKit sends the push notification using a lower priority and doesn't display any content." ([NotificationInfo](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class))
- `alertLocalizationArgs` are *record field names*; CloudKit fills in their values (strings, numbers or dates; strings over 100 characters may be cut). ([alertLocalizationArgs](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/alertlocalizationargs)) So the alert text can include the device name and level without the app running.
- `shouldSendContentAvailable` defaults to false. ([shouldSendContentAvailable](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/shouldsendcontentavailable))
- CloudKit query predicates support `<`, `>`, `==`, `AND`, `BEGINSWITH`, `IN` and more, on string, number, date and reference fields; they must be format-string predicates. ([CKQuery](https://developer.apple.com/documentation/cloudkit/ckquery)) So `level < 20` is a valid subscription predicate. The field must be queryable in the Production schema.
- A subscription "applies only to the user that creates it", and the server excludes the originating device "when appropriate". Query subscriptions work in the private database. ([CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription))

#### Options

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

#### Rest of the design (outline)

- Thresholds: stored per device; owned by ADR-0005 (a field on `DeviceBattery` or a small settings record). The reporter reads its own threshold.
- Cycle tracking in the reporter: `armed` when charging or level ≥ threshold + 10; when armed and level < threshold and not charging, write the event and disarm. State kept in the App Group (ADR-0009). Pure logic in `Shared`, unit-tested with Swift Testing (ADR-0018).
- Notification permission: ask with `UNUserNotificationCenter.requestAuthorization` when the user turns alerts on, not at first launch.
- watchOS: rely on iPhone notification mirroring first. **Assumption:** a CloudKit alert to the iPhone app mirrors to the Watch when the iPhone is locked, like other iPhone notifications.
- Cleanup: any device deletes `LowBatteryEvent` records older than 7 days when it runs.
- Mac: the agent registers for remote notifications and shows alerts through `UNUserNotificationCenter`; a menu-bar-only app can still post notifications. **Assumption:** to verify with ADR-0014's agent setup.

#### Edge cases (iCloud)

- Level jumps from 22% to 12% between reports: still one alert, with the reported level.
- Device charging when the event is created: not created (R2).
- Two writers for one device (reinstall with new ID): ADR-0007 decides; worst case two alerts.
- Low device offline (no network): event saved when it reconnects, probably late; R5 drops it if older than 1 hour (needs the service extension or a foreground check).
- iCloud signed out on the receiver: no alerts; nothing to do.
- Focus modes may hide the alert; use a `category` and consider Time Sensitive interruption level later (**Assumption:** CloudKit `NotificationInfo` has no interruption-level field; needs a service extension to set it).

#### Acceptance criteria (iCloud, not in this build)

- AC-C1 — Given Mac threshold 20% and alerts on, when the Mac discharges from 30% to 5%, then the iPhone shows exactly one alert naming the Mac.
- AC-C2 — Given the iPhone app was force-quit, when the Mac crosses its threshold, then the iPhone still shows the alert.
- AC-C3 — Given the Mac was charged to 50% after an alert, when it discharges below 20% again, then a second alert is shown.

AC-C1–C3 are manual real-device cases in a later QA spec, including a check of Option B's "fires on every update" assumption with a throwaway subscription in a separate test container (ADR-0018 §6).
