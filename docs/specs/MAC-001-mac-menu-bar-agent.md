---
id: MAC-001
title: Mac menu-bar agent
milestone: v0.1
status: Draft
depends_on: [SYNC-001, SYNC-002, MAC-002, UI-004]
adrs: [6, 10, 13, 14, 16]
targets: [Levels-Mac]
---

# MAC-001: Mac menu-bar agent

## Why

The Mac is the device you can't check without opening it, and it is also the one place that can report accessories. A small agent that starts at login, sits in the menu bar and reports quietly gives every other device a fresh Mac reading, and gives the Mac a view of everything else.

## Scope

- In: app lifecycle; `LSUIElement` agent; `MenuBarExtra` scene hosting UI-004's content; the device window (a `Window` scene with the same content, opened by `levels://` URLs); Settings window (open at login, show in menu bar, quit); login item via `SMAppService`; sleep/wake hooks; remote-notification registration and silent-push handling on macOS; signing, entitlements and Info.plist for the Developer ID build (ADR-0013); notarization script.
- Out (and where it goes instead): popover content and the menu-bar icon design (UI-004); desktop widgets (ADR-0017, UI-*); reading the Mac battery (MAC-002); accessories (MAC-003); CloudKit records, subscriptions and the rate limit (SYNC-001, SYNC-002); alerts (ALR, v0.4).

## Behaviour

- **R1** — The app has no Dock icon and no app menu bar (`LSUIElement = YES`). Its only always-visible UI is one menu-bar item.
- **R2** — Clicking the menu-bar item opens a window-style popover showing UI-004's content. Clicking outside or pressing Esc closes it.
- **R2a** — **Device window.** Lead's call (2026-11-23): the app has one SwiftUI `Window` scene (id `devices`, title "Levels") showing UI-004's popover content at window size. It is not shown at launch. It opens, and the app activates (`NSApp.activate()`), when a `levels://` URL arrives (a desktop widget click, UI-004 R14): the scene declares `.handlesExternalEvents(matching: ["levels"])` and its view handles `onOpenURL`, scrolling to the device in `levels://device/<uuid>`. This is how code shows the device list, because the `MenuBarExtra` popover can't be opened from code. Closing the window leaves the agent running. **Assumption:** SwiftUI routes `levels://` to the suppressed `Window` scene (not the `MenuBarExtra`) both while the app is running and on cold launch; verify in QA-001 for both cases. **Assumption:** with the menu-bar item hidden (R4(c)), closing the device window doesn't quit the app; verify in QA (fallback: `applicationShouldTerminateAfterLastWindowClosed` returns `false`).
- **R3** — The popover footer (provided by UI-004, wired here) has **Settings…** (⌘,) and **Quit Levels** (⌘Q).
- **R4** — Settings has:
  - (a) **Open at login**, a toggle reflecting `SMAppService.mainApp.status` (on only for `.enabled`);
  - (b) when the status is `.requiresApproval`, the text "Allow Levels in System Settings → Login Items" and a button that calls `SMAppService.openSystemSettingsLoginItems()`;
  - (c) **Show in menu bar**, a toggle stored in `UserDefaults` key `showMenuBarItem` (default `true`) and bound to `MenuBarExtra(isInserted:)`;
  - (d) the app version and "Quit Levels".
- **R5** — If the app is launched while already running (from Finder, Spotlight or `open`), it opens the device window (R2a) and the Settings window and brings them to the front. This is how the user recovers when the menu-bar item is hidden by R4(c) or by macOS **Allow in the Menu Bar**. Lead's call (2026-11-23): Settings is opened only from a SwiftUI context, with the `openSettings` environment action (or `SettingsLink`), never from `NSApplicationDelegate`. So `applicationShouldHandleReopen` only sets `model.settingsRequested = true` and returns `true`; SwiftUI then shows the device window, whose view sees the flag, calls `openSettings()` once and clears it. **Assumption:** SwiftUI shows the `Window` scene on reopen when no window is visible; if not, the delegate opens `levels://settings` with `NSWorkspace.shared.open`, which the device window's URL handling turns into the same `openSettings()` call.
- **R6** — Lead's call (2026-11-23): open at login is on by default, with the R4(a) toggle to turn it off. On the very first launch (no `UserDefaults` key `didOfferLoginItem`), the app calls `SMAppService.mainApp.register()` once and sets `didOfferLoginItem = true`. It never re-registers by itself after that. Only the R4(a) toggle calls `register()` / `unregister()`.
- **R7** — Before reading or syncing anything, the app makes sure the Mac's `deviceId` exists (SYNC-001/SYNC-002 own creation). It then starts MAC-002's reporter, which keeps running until the app quits.
- **R8** — On launch the app calls `NSApplication.shared.registerForRemoteNotifications()`. On success it hands the token to SYNC-001 if SYNC-001 needs it (CloudKit manages its own token; **Assumption:** no app action beyond registration is needed). On failure it logs and continues: the app still reports, but it learns about other devices only when it fetches on popover open, on wake, and every 15 minutes (see R11).
- **R9** — When a remote notification arrives (`application(_:didReceiveRemoteNotification:)`), the app passes the payload to SYNC-001, which fetches changes and updates the App Group snapshot. SYNC-001 requests the widget reload itself when the cache changed (SYNC-001 R8a); the app does not call `reloadAllTimelines()`. After SYNC-001 returns, the app calls `reporter.report(reason: .pushWake)` (MAC-002), because SYNC-001's push handler takes no own reading (SYNC-001 R12). An open popover updates without being reopened.
- **R10** — **On `NSWorkspace.willSleepNotification`**, the app calls `reporter.report(reason: .sleep)` (MAC-002) and does not wait for the save or delay sleep (ADR-0014).
  **On `NSWorkspace.didWakeNotification`**, the app calls `reporter.report(reason: .wake)`, then `sync.refresh(.wake)` (SYNC-001), which also re-checks the subscription.
- **R10a** — When the network becomes reachable again (`NWPathMonitor` path changes to `.satisfied` after being unsatisfied), the app calls `sync.refresh(.networkReachable)` (SYNC-001 R13, ADR-0006 rule 3). This is event-driven, not a timer.
- **R11** — Fallback refresh: while push registration has failed, or no push has arrived for 15 minutes, the app asks SYNC-001 to fetch changes every 15 minutes (a timer with ≥ 60 s tolerance); once a push arrives again, the timer stops. This timer and MAC-002's 30-minute heartbeat (R6f) are the agent's only timers in v0.1–v0.2 (ADR-0014 rule 5). Opening the popover also triggers a fetch, at most once a minute.
- **R12** — Quitting ends the process immediately. There is no "are you sure" prompt, and no work continues in the background.
- **R13** — The app starts no helper processes, launch agents or XPC services. The one exception is MAC-003's `system_profiler` run, at v0.3.

## Design

**Modules**
- `Levels-Mac` app target, Swift 6 language mode, strict concurrency complete. Depends on the `Shared` package: models, `BatterySyncService` (SYNC-001), the `BatteryReader` protocol (ADR-0010) and UI views (UI-004).

**Types (sketch; Builder's call on names)**

```swift
@main
struct LevelsMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("showMenuBarItem") var showMenuBarItem = true
    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarPopoverView()          // from UI-004
                .environment(appDelegate.model)
        } label: { MenuBarLabel() }       // from UI-004
        .menuBarExtraStyle(.window)
        Window("Levels", id: "devices") {   // R2a: opened by levels:// URLs and reopen, never at launch
            DeviceWindowView()            // UI-004 popover content; onOpenURL, calls openSettings() when model.settingsRequested (R5)
                .environment(appDelegate.model)
        }
        .handlesExternalEvents(matching: ["levels"])
        .defaultLaunchBehavior(.suppressed)
        Settings { MacSettingsView().environment(appDelegate.model) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: MacAppModel
    func applicationDidFinishLaunching(_ n: Notification)
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool // R5: sets model.settingsRequested only; never opens Settings itself
    func application(_ a: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data)
    func application(_ a: NSApplication, didFailToRegisterForRemoteNotificationsWithError e: Error)
    func application(_ a: NSApplication, didReceiveRemoteNotification info: [String: Any])
}

@MainActor @Observable final class MacAppModel {
    let reporter: MacBatteryReporter      // MAC-002
    let sync: BatterySyncService          // SYNC-001
    let loginItem: LoginItemController
    func start() async                    // R7, R8, R10, R11
}

@MainActor @Observable final class LoginItemController {
    private(set) var status: SMAppService.Status
    func refresh()                        // re-reads SMAppService.mainApp.status
    func setEnabled(_ on: Bool) throws    // register / unregister
    func registerOnFirstLaunchIfNeeded()  // R6
}
```

- **Sleep and wake:** observe with `NSWorkspace.shared.notificationCenter.notifications(named:)` in a `Task` owned by `MacAppModel` (main actor). Never use `NotificationCenter.default` for these (QA1340).
- **Settings from an LSUIElement app:** use `SettingsLink` in the popover and the device window, or the `openSettings` environment action from a SwiftUI view (R5), and call `NSApp.activate()` so the window comes to the front. Never open Settings from `NSApplicationDelegate` or with `NSApp.sendAction(Selector(("showSettingsWindow:")))` (lead's call 2026-11-23). **Builder's call:** use `openSettings` instead of `SettingsLink` if `SettingsLink` misbehaves inside `MenuBarExtra`.
- **CloudKit linking:** add `CloudKit.framework` to the Mac target's "Link Binary With Libraries" and add `print(CKContainer.self)` at the top of `applicationDidFinishLaunching`. This avoids the macOS 26 sandbox `com.apple.cloudd` denial (ADR-0013). The `print` line is belt-and-braces; `otool -L` is the real check.

**Info.plist (Levels-Mac)**

| Key | Value |
|---|---|
| `LSUIElement` | `YES` |
| `LSMinimumSystemVersion` | `26.0` |
| `LSApplicationCategoryType` | `public.app-category.utilities` |
| `CFBundleDisplayName` | `Levels` |
| `NSBluetoothAlwaysUsageDescription` | not in v0.1 (MAC-003 decides at v0.3) |

**Entitlements (Developer ID, v0.1–v0.2; ADR-0013)**

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | ADR-0013: keep the App Store path open until v0.3 |
| `com.apple.developer.icloud-services` | `[CloudKit]` | SYNC-001 |
| `com.apple.developer.icloud-container-identifiers` | `[iCloud.<rdns>.levels]` (name owned by SYNC-001) | SYNC-001 |
| `com.apple.developer.icloud-container-environment` | `Production` in Debug and Release (set in the entitlements file, not by export) | Owner decision (2026-11-23): every daily build, debug included, uses Production (ADR-0005 rule 5) |
| `com.apple.developer.aps-environment` | Entitlements file (Debug and Release): `development`; the exported Developer ID build carries `production`, set by export (owner decision I; lead's call 14: a development profile only allows `development`) | silent push. Whether a Debug build gets pushes from the Production container is checked by [SPIKE-001](SPIKE-001-debug-build-push-check.md) |
| `com.apple.security.application-groups` | `[<TEAMID>.<rdns>.levels]` (ADR-0003, ADR-0009; the Mac widget uses the same ID) | snapshot shared with Widgets-Mac |
| `com.apple.security.network.client` | `true` | **Assumption:** CloudKit traffic goes through `cloudd`, so this may not be needed. Kept because it is harmless and covers anything Shared does directly. |

- The Hardened Runtime is on, with no exceptions.
- A Developer ID provisioning profile with iCloud, Push and App Groups is embedded. At v0.3 MAC-003 sets `com.apple.security.app-sandbox = false` for the Developer ID configuration only.

**Build and notarize (owner's machine)**

- `scripts/release-mac.sh` (builder writes it) runs these steps:
  1. `xcodebuild archive`
  2. `xcodebuild -exportArchive` with method `developer-id`
  3. `ditto -c -k` into a zip
  4. `xcrun notarytool submit --wait` with a keychain profile
  5. `xcrun stapler staple` on the `.app`, then re-zip
- `spctl -a -vv Levels.app` must report "source=Notarized Developer ID".

**Concurrency**

- Everything in this spec runs on the main actor. Work off the main actor (CloudKit, IOKit reads) is owned by SYNC-001 and MAC-002, through `async` APIs. No `@unchecked Sendable` in this target. No `DispatchQueue.main.async`; use `Task { @MainActor in }` where a callback needs to come back.

## Edge cases and failure modes

- **No iCloud account, or iCloud Drive off.** SYNC-001 reports the state, and the popover shows UI-004's "Sign in to iCloud" state. The agent keeps reading the battery and saves nothing.
- **Account changes (`CKAccountChanged`).** Handled by SYNC-001. The agent doesn't restart.
- **Login item approval pending.** R4(b). Reporting works whenever the app is running.
- **User disables the login item in System Settings.** The status becomes `.notRegistered` or `.notFound`, and the toggle shows off. R6 guarantees no silent re-registration.
- **Menu-bar item hidden by the system ("Allow in the Menu Bar" off).** Reporting continues; R5 gives a way back.
- **Many menu-bar items / notch overflow.** The item may be hidden behind the notch. Same recovery as above.
- **Push registration fails.** This happens when the profile is missing or the build is ad-hoc. R8/R11 polling covers it.
- **Sleep before the save finishes.** The reading is lost. The record still holds the last accepted write (within ADR-0008's 5-point steps and 30-minute heartbeat), and wake reports immediately as an urgent `.wake` report (R10).
- **Two copies of the app** (e.g. Debug and Release builds). Both use the Production environment (ADR-0005 rule 5), so don't run them side by side on one Mac: one copy at a time. If a second copy got its own `deviceId`, the Mac shows twice until the extra row ages into "Old devices" and is removed (UI-004 R9). Experiments that must not touch the owner's data use a separate container or test setup (ADR-0018 §6).

## Acceptance criteria

- [ ] AC1 — Given the app is launched, when it finishes launching, then no Dock icon appears and one menu-bar item appears. (UI test + manual)
- [ ] AC2 — Given the menu-bar item, when it is clicked, then a window-style popover shows UI-004's content; when Esc is pressed, it closes. (UI test)
- [ ] AC3 — Given a first launch on a clean user account, when launch completes, then `SMAppService.mainApp.status` is `.enabled` or `.requiresApproval`, and `didOfferLoginItem` is `true`. (Manual on real Mac)
- [ ] AC4 — Given the user turned Open at login off, when the app is relaunched, then the status is still not `.enabled` (no re-registration). (Unit test with a fake `SMAppService` wrapper + manual)
- [ ] AC5 — Given login is enabled, when the user logs out and back in, then Levels is running within 30 s of login and its menu-bar item is visible. (Manual on real Mac)
- [ ] AC6 — Given status `.requiresApproval`, when Settings opens, then the approval text and button show, and the button opens Login Items in System Settings. (Unit test on the view model + manual)
- [ ] AC7 — Given Show in menu bar is off and the app is running, when the user opens Levels from Finder, then the device window and the Settings window come to the front, with Settings opened by `openSettings` from the window's view (R5). (Manual)
- [ ] AC7a — Given the app is running, when `open levels://device/<id>` runs, then the device window opens in front with that device highlighted and the popover stays closed (R2a, UI-004 R14). (Manual)
- [ ] AC8 — Given the app is running, when the Mac sleeps and wakes, then within 10 s of wake the Mac's record has a new `updatedAt` (seen from another device or the CloudKit console). (Manual on real Mac)
- [ ] AC9 — Given a second device changes its record, when the silent push arrives, then the open popover shows the new value within 10 s without being reopened. (Manual, two real devices; push timing is not under our control)
- [ ] AC10 — Given push registration failed (simulated by a fake), when 15 minutes pass, then a fetch is requested. (Unit test with an injected clock)
- [ ] AC11 — Given the exported Developer ID build, when `codesign -d --entitlements - Levels.app` runs, then the entitlements match the table above, `spctl -a -vv` reports Notarized Developer ID, and `otool -L` lists `CloudKit.framework`. (Release checklist, scripted)
- [ ] AC12 — Given the release build launched from `/Applications` by double-click (not Xcode), when it saves its first record, then no `deny mach-lookup com.apple.cloudd` appears in `log show --predicate 'sender == "Sandbox"'` and no `CKError 6` is logged. (Manual on real Mac)
- [ ] AC13 — Given the app is idle for 60 minutes on battery with the popover closed, when Activity Monitor's Energy tab is read, then the "Avg Energy Impact" for Levels is below 1.0 and the app shows no "Preventing Sleep". (Manual on real Mac)
- [ ] AC14 — Given Quit is chosen, when the process ends, then no Levels process remains (`pgrep -x Levels` is empty). (Manual / UI test)

## Tests

- **Unit (Swift Testing):**
  - `LoginItemController`, behind a protocol wrapping `SMAppService`: AC4, AC6.
  - The fallback timer, with an injected clock: AC10.
  - The R6 first-launch rule.
- **UI tests (XCUITest on macOS):** AC1, AC2 and AC14, as far as XCUITest can reach a menu-bar extra. **Assumption:** XCUITest can click `MenuBarExtra` items on macOS 26; if not, these are manual.
- **Real hardware, manual:** AC3, AC5, AC7, AC8, AC9, AC12 and AC13. Login items, sleep/wake, push delivery, sandbox and CloudKit behaviour, and energy all need a real signed build on a real Mac. AC11 is a scripted release check.

## Open questions

- None. Lead's call (2026-11-23): Open at login is on by default with a toggle (R6).
