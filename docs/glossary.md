# Glossary

Short definitions of terms used across the README, ADRs and specs. When a document owns the detailed rule, it is named in brackets.

| Term | Meaning |
|---|---|
| **Device** | An Apple device that runs Levels and reports its own battery: iPhone, iPad, Mac or Apple Watch. Has one `DeviceBattery` record. A desktop Mac with no internal battery still has one, with no `level`; it is shown as "plugged in, no battery". [ADR-0005, ADR-0007, ADR-0015] |
| **Accessory** | Something with a battery that can't run Levels (AirPods, Magic Mouse, Keyboard, Trackpad). A Mac reports it while it is connected to that Mac. From v0.3. [ADR-0015] |
| **Parent device** | The device that last reported an accessory. Stored as `parentDeviceId` on the accessory's record. Always a Mac; if two Macs see the same accessory, it means "last seen on". [ADR-0005, ADR-0015] |
| **Device ID** | A stable random UUID that identifies one device, kept in the Keychain so it survives app updates. [ADR-0007] |
| **Device name** | The name shown for a device, stored in its own record. Default: the model name ("iPhone", "iPad", "Apple Watch"), or the Mac's computer name. The user can rename **this** device in the app, and the name syncs to every device. Can contain a person's name, so treated as personal data. [ADR-0007, SYNC-002 R17, ADR-0019] |
| **Reading** | One battery measurement taken on a device: level (0–100, or none), power state, Low Power Mode. Type `BatteryReading`. [ADR-0010] |
| **Charging** (`isCharging`) | Charging, or on external power and full: `charging \|\| (onExternalPower && full)`. A battery held below full on the charger is not charging. [SYNC-002 R16] |
| **Plugged in** (`isPluggedIn`) | On external power, whether charging, full, held at a limit, or a desktop Mac. [SYNC-002 R16] |
| **Report** | A device handing its latest reading to sync, which writes it to the device's own record when ADR-0008 says so (state changes at once, level in 5-point steps at most once a minute, a 30-minute heartbeat). [ADR-0008, SYNC-001, RPT specs] |
| **Urgent report** | A report whose reason is launch, App Intent, Mac sleep, Mac wake, a charger change or a user refresh (pull to refresh, refresh button, ⌘R). It skips the 60 s minimum gap but keeps the 10 s floor. [ADR-0008 W9, SYNC-001 R5a] |
| **Heartbeat** | A write that only refreshes `updatedAt` when the last accepted write is 30 min old and the process is awake. The Mac agent triggers one every 30 min. [ADR-0008 W6, MAC-002] |
| **Reporter** | The device (or Mac, for accessories) that writes a record. A device record has exactly one reporter; an accessory record may be written by more than one Mac (newest `updatedAt` wins). |
| **Snapshot** | The latest known readings of all devices, as cached on one device in the App Group (`snapshot.json`, type `SnapshotFile`, read and written through `SnapshotCache` in `LevelsModel`) so widgets can draw at once. Not a single device's reading. [ADR-0009, SYNC-002] |
| **`updatedAt`** | When the reporter took the reading. Drives "updated X min ago" and staleness. |
| **Stale** | A reading older than its threshold: 2 h for iPhone, iPad and Watch; 65 min for Macs and accessories; 30 min for a Mac or accessory actively charging below 100 % (iPhone, iPad and Watch keep 2 h while charging). Shown dimmed and marked, never hidden. [ADR-0017, SYNC-002 R10] |
| **Old device** | A device whose reading is 30 days old or more; grouped under "Old devices", where it can be removed by hand (never automatically). [ADR-0005, UI-002 R11] |
| **Hidden device** | A device the user hid on one device. Hiding is local to that device in v0.1. [UI-001] |
| **Private database** | The user's own CloudKit database. Only that Apple ID can read it; the developer can't. All Levels data lives here. [ADR-0004, ADR-0019] |
| **Zone** | A CloudKit record zone. Levels keeps its records in one custom zone, which can be deleted or shared as a whole. [ADR-0005] |
| **Subscription** | A rule saved in CloudKit that makes the server send a push when matching records change. Sync uses one silent `CKDatabaseSubscription` (`levels-private-db`); v0.4 alerts may add a query subscription on the `Levels` zone. [ADR-0006, ALR-001] |
| **Silent push** | A background push with no alert or sound. Wakes the app for about 30 s to fetch changes. Low priority, may be delayed, throttled or dropped (Apple says don't expect more than 2–3 an hour). |
| **Visible alert push** | A push that shows a notification to the user. Normal priority. Used for low-battery alerts. [ALR-001] |
| **Widget reload budget** | How many times WidgetKit lets a widget refresh per day, typically 40–70 for a widget the user often sees. Why widgets lag by minutes. [ADR-0017] |
| **App Intent "Report Battery"** | An action Shortcuts can run to make the iPhone report without opening the app. [ADR-0011, RPT specs] |
| **Shortcuts automation** | A personal automation that runs "Report Battery" when the battery crosses a level. The most reliable iPhone background trigger. |
| **Background refresh** | `BGAppRefreshTask`: iOS lets the app run briefly at times it chooses. Irregular. [ADR-0011] |
| **Mac agent** | The Mac menu-bar app (no Dock icon) that starts at login and reports continuously while the Mac is awake. [ADR-0014] |
| **Device window** | The Mac app's normal window (a SwiftUI `Window` scene) showing the same list as the menu-bar popover. Opened by `levels://` links, such as a desktop widget click, and by relaunching the app; the popover itself can't be opened from code. [MAC-001 R2a, UI-004 R14] |
| **Discharge cycle** | The time from one charge to the next. Low-battery alerts fire at most once per cycle per device. [ALR-001] |
| **Threshold** | The level (default 20%) below which a device triggers a low-battery alert. Set per device. [ALR-001] |
| **History** | The last 7 days of readings for a device, used for charts. [HIS-001] |
| **Nearby mode** | Optional, later: Mac sends its battery to a nearby iPhone over Bluetooth LE, without iCloud. [NRB-001] |
| **Owner / participant** | In family sharing, the owner shares their devices; participants are invited people who can see them. [FAM-001] |
| **Development / Production environment** | CloudKit's two copies of the database. Every Levels build used day to day, Xcode debug builds included, uses Production; experiments use a separate container or test setup. Schema must be deployed before Production works. Separate from the push environment (`aps-environment`): `development` in Debug builds, `production` in TestFlight, release and Developer ID builds; SPIKE-001 checks Debug builds still get pushes. [ADR-0005, ADR-0018, SPIKE-001] |
| **Privacy manifest** | `PrivacyInfo.xcprivacy`, a file in each target that declares collected data and required-reason APIs. [ADR-0019] |
| **Required-reason API** | An Apple API (such as `UserDefaults`) that needs a declared reason code in the privacy manifest. [ADR-0019] |
| **Real-device test** | A manual test on physical hardware, from a QA spec, because the Simulator can't reproduce batteries, pushes or widget timing. [ADR-0018, QA-001] |
