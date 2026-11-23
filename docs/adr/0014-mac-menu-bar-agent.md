# ADR-0014: Run the Mac app as a SwiftUI MenuBarExtra agent that starts at login

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0013, ADR-0010, ADR-0016/0017 (UI), MAC-001, MAC-002, UI-004

## Context

The Mac reports its battery continuously while awake (README) and shows every device in a menu-bar popover (UI-004). It must start by itself after login, cost almost no energy, and behave sensibly around sleep.

### Facts verified

- **No Dock icon.** `LSUIElement = YES` hides the Dock icon and the app menu. A SwiftUI `MenuBarExtra` scene with `.menuBarExtraStyle(.window)` shows arbitrary SwiftUI in a popover-like window. The `MenuBarExtra(isInserted:)` initialiser lets a setting hide the item. ([MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra))
- **Status item visibility on macOS 26.** macOS 26 has a **Menu Bar → Allow in the Menu Bar** list, and the user can hide our item there. DTS says status items work best when the app goes through `NSApplicationMain` (SwiftUI `App` does this) and the item is owned by the main process, not a helper. On macOS 26 the system also warns about background processes that run without UI after the app closes. ([forum 794920](https://developer.apple.com/forums/thread/794920))
- **Login item.** `SMAppService.mainApp.register()` registers the app itself to open at login, with no helper bundle. The status can be `.enabled`, `.requiresApproval` (the user must allow it in System Settings → General → Login Items), `.notRegistered` or `.notFound`. Forum reports say a user who turns it off in System Settings can leave the status at `.notFound`. ([SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp), [forum 760186](https://developer.apple.com/forums/thread/760186))
- **Sleep and wake.** `NSWorkspace.willSleepNotification` and `didWakeNotification` arrive on `NSWorkspace.shared.notificationCenter`, not the default centre. At the IOKit level (`IORegisterForSystemPower`), an app that does not acknowledge `kIOMessageSystemWillSleep` delays sleep by **at most 30 seconds**. ([QA1340](https://developer.apple.com/library/archive/qa/qa1340/_index.html)) **Assumption:** the `NSWorkspace` notification gives no guaranteed window, and the network may already be going down. A CloudKit save started in `willSleep` may or may not finish.
- **No polling needed.** `IOPSNotificationCreateRunLoopSource` calls back when any power-source value changes (MAC-002), so the app is idle between changes.

## Decision

1. **App shape:** a SwiftUI `App` with a `MenuBarExtra` scene in `.window` style, a `Window` scene (the device window, same content as the popover), and a `Settings` scene. Lead's call (2026-11-23): the `MenuBarExtra` popover can't be opened from code, so anything that must show the device list from code (a desktop widget click, a relaunch) opens the device window through its `levels://` URL handling (MAC-001 R2a, UI-004 R14). Settings is opened with SwiftUI's `openSettings` action or `SettingsLink` from a SwiftUI view or scene, never from `NSApplicationDelegate` (MAC-001 R5). `LSUIElement = YES`. No helper process, no XPC service, no launch agent: one process does reading, syncing and UI.
2. **Login item:** on first launch the app calls `SMAppService.mainApp.register()` once (default on, since the agent is pointless if it is not running). Settings has a "Open at login" toggle bound to the live `SMAppService.mainApp.status`. It is re-read whenever Settings opens, and `.requiresApproval` shows a button that calls `SMAppService.openSystemSettingsLoginItems()`. If the user turns it off in System Settings, the app does not register it again. Lead's call (2026-11-23): open at login is on by default, with the toggle to turn it off.
3. **Sleep and wake:**
   - **On `willSleep`:** best-effort report. Start one save of the current reading as an urgent `.sleep` report (ADR-0008 W9: skips the 60 s gap, keeps the 10 s floor) and don't wait for it. Don't use `IORegisterForSystemPower` to hold sleep: delaying the owner's sleep for a battery record isn't worth it, and the record is already within ADR-0008's limits (5-point steps, 30-minute heartbeat).
   - **On `didWake`:** read and report right away as an urgent `.wake` report (ADR-0008 W9). Then re-check the CloudKit subscription and fetch changes, as SYNC-001 defines for a resume.
4. **App Nap:** don't use `ProcessInfo.beginActivity` by default. The IOPS run-loop source and silent pushes wake the app even when it is napping. **Assumption:** App Nap does not delay the IOPS callback noticeably; MAC-002 AC checks it on hardware. If it does, wrap only the read-and-save in `beginActivity(options: .userInitiated, reason:)` and end the activity right after.
5. **Energy:** lead's call (2026-11-23): in v0.1–v0.2 the agent has **exactly two timers, both with tolerance**: the 30-minute heartbeat (MAC-002 R6f, 5 min tolerance) and the 15-minute fallback fetch, which runs only while pushes appear missing (push registration failed, or no push for 15 minutes; MAC-001 R11, ≥ 60 s tolerance). Everything else is event-driven; SYNC-001's one-shot waits (a held write, SYNC-001 R5; retry back-off, R16) are not periodic timers. v0.3 adds a third, the accessory poll: every 5 minutes while AirPods are connected, otherwise every 15 minutes (ADR-0015, MAC-003 R2). Target: Activity Monitor's average "Energy Impact" for Levels stays under 1.0 over an hour of idle use. **Assumption:** reachable without extra work.
6. **Quit:** the popover footer (UI-004) and the Settings window have Quit (⌘Q). Quitting stops reporting until the next launch or login, and the UI's "updated X min ago" makes that visible.

## Options considered

### Option A — SwiftUI `MenuBarExtra` (`.window`) (chosen)
- Pros: pure SwiftUI, shares views with the other platforms (ADR-0016), no AppKit glue. The `isInserted` binding gives a "Show in menu bar" toggle. Goes through `NSApplicationMain`, which macOS 26 expects.
- Cons: little control over the window (no programmatic open, no anchoring tweaks); right-click menus are awkward. Accepted: code-driven opens use the separate device `Window` scene instead (Decision 1).

### Option B — AppKit `NSStatusItem` + `NSPopover` hosting SwiftUI
- Pros: full control (programmatic show, right-click menu, a dynamic icon drawn from levels).
- Cons: more AppKit code to maintain under Swift 6 main-actor rules. Kept as the fallback if UI-004 needs something `MenuBarExtra` can't do. The switch stays within the Mac target.

### Option C — Separate background helper (launch agent) + UI app
- Pros: reporting survives quitting the UI.
- Cons: two processes, IPC, and the macOS 26 status-item and background-visibility issues above. Over-built for a personal tool.

## Consequences

- Positive: one small process, idle except when the battery changes or a push arrives; starts at login.
- Negative / accepted risks: a sleeping or quitted Mac stops reporting, which the README accepts. If the user hides the item via Allow in the Menu Bar, the agent keeps reporting but has no visible UI. Relaunching the app from Finder opens the device window and Settings (MAC-001 R5) so the user can recover.
- Follow-ups: measure energy impact on hardware (MAC-001 AC). Revisit Option B if UI-004 needs a dynamic menu-bar icon.

## References

- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- SMAppService.mainApp: https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp
- NSWorkspace.willSleepNotification: https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification
- QA1340, registering for sleep and wake: https://developer.apple.com/library/archive/qa/qa1340/_index.html
- Forum 794920, status items on macOS 26: https://developer.apple.com/forums/thread/794920
- Forum 760186, user changes to login items: https://developer.apple.com/forums/thread/760186
- ProcessInfo.beginActivity: https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)
