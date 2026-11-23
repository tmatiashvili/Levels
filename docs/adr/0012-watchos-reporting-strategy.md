# ADR-0012: The watch reports straight to CloudKit on activation, background refresh and push wake-ups

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0006, ADR-0008, ADR-0010, ADR-0011, RPT-004, SYNC-001

## Context

The watch has the same problem as the iPhone (the app is suspended most of the time), with tighter limits and no Shortcuts automation to lean on.

Verified facts:

- `WKInterfaceDevice.batteryLevel` and `batteryState` work once `isBatteryMonitoringEnabled` is `true`; otherwise −1.0 / `.unknown`. ([batteryLevel](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel))
- **Background refresh.** `scheduleBackgroundRefresh(withPreferredDate:userInfo:scheduledCompletion:)` allows one pending task at a time; a second call cancels the first; the system may delay it when the app is over budget. ([scheduleBackgroundRefresh](https://developer.apple.com/documentation/watchkit/wkapplication/schedulebackgroundrefresh(withpreferreddate:userinfo:scheduledcompletion:))) The budget is "approximately four tasks per hour for each app with a complication on the active watch face", shared by all its complications. SwiftUI `backgroundTask(_:action:)` is the preferred handler since watchOS 9. ([WKApplicationRefreshBackgroundTask](https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask))
- Background tasks are "strictly limited", not guaranteed, and the system "gives priority to apps with a complication in the active watch face and apps in the dock". ([Keeping your watchOS content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date))
- **CloudKit on the watch** is native. Requests go through the paired iPhone, known Wi-Fi or cellular automatically. `CKSubscription` and its notifications work on watchOS 6 and later, "a potential replacement for Watch Connectivity". (same article)
- **WatchConnectivity** should be "an opportunistic optimization, rather than the primary means" because the phone is often out of reach. (same article) `transferCurrentComplicationUserInfo` is phone-to-watch only, 50 per day with an active complication. ([remainingComplicationUserInfoTransfers](https://developer.apple.com/documentation/watchconnectivity/wcsession/remainingcomplicationuserinfotransfers))
- **Silent push** on watchOS: remote-notification background mode on the watch target; `apns-push-type: background` is required for Apple Watch; 30 seconds of run time; not guaranteed. ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)) Developer forum posts report unreliable CloudKit silent pushes on watchOS ([forum 126286](https://developer.apple.com/forums/thread/126286)) — anecdotal.
- **Shortcuts.** On the watch you run shortcuts by tapping them; Apple's watch pages describe no automations. ([Run shortcuts from Apple Watch](https://support.apple.com/guide/shortcuts/apd5888b0858/ios)) Personal automations are device-specific and don't sync. ([Add automations](https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios))
  - **Assumption:** watchOS 26 has no personal automations, so no Battery Level trigger on the watch.
  - **Assumption:** an iPhone automation cannot read the watch's battery level through any public Shortcuts action.
- **Assumption:** `WKInterfaceDevice` battery values are not readable from the watch widget (complication) extension. Not verified.

## Decision

The watch app reports its own battery **directly to CloudKit** through the same Shared `BatterySyncService` (SYNC-001). No WatchConnectivity in v0.2. Triggers, all calling the shared `BatteryReporter.reportNow(reason:)` (RPT-001, reused by RPT-004):

1. **App becomes active** (launch, wrist raise with the app in front, return to the app).
2. **Background app refresh** via SwiftUI `.backgroundTask(.appRefresh)`; after each run and each foreground session, schedule the next one 30 minutes ahead. With a Levels complication on the active face this gives up to ~2 runs per hour; without one, expect few or none.
3. **Silent push** from another device's change (ADR-0006): report self while awake, like iPhone (ADR-0011).
4. **Complication timeline reloads do not read the battery.** They render from the App Group cache (ADR-0009) only.

Owner decision (2026-11-23): the owner will keep a Levels complication on the daily watch face. This is the operating assumption for RPT-004, UI-006 and QA-002: it is what earns background time. The setup guide still says so for anyone else.

## Options considered

### Option A — direct CloudKit from the watch (chosen)
- Pros: works away from the iPhone (Wi-Fi, cellular); one code path shared with iPhone and Mac; Apple's recommended model for independent apps.
- Cons: CloudKit calls on the watch are slower and cost watch battery; depends on the watch's limited background time.

### Option B — WatchConnectivity to the iPhone, iPhone writes the watch's record
- Pros: phone has more background time; no CloudKit write from the watch.
- Cons: needs the iPhone awake and reachable at the same moment — the iPhone app is usually suspended too; two writers for one record conflict with ADR-0005/0007 (each device owns its record); Apple calls it opportunistic only. **Rejected for v0.2.**

### Option C — both (watch → CloudKit, plus `transferUserInfo` to iPhone as backup)
- Pros: a second chance when the watch has no network.
- Cons: the watch proxies through the iPhone anyway when nearby, so the extra path rarely adds anything; more code and a second writer. Revisit if field data shows gaps.

### Option D — Shortcuts automations
- Pros: worked well on iPhone (ADR-0011).
- Cons: not available on the watch (Assumption); an iPhone automation can't read the watch level (Assumption). **Not possible.**

### Option E — read battery in the complication timeline provider
- Pros: complications reload often.
- Cons: unverified API access in the extension; extensions shouldn't do CloudKit writes; second writer. **Rejected.**

## Consequences

- Positive: one simple model on every device: "each device writes its own record".
- Negative / accepted risks: the watch can go hours without reporting when its app isn't used and no complication is active. The UI's "updated X ago" shows that. Watch reports cost a little watch battery.
- Follow-ups: measure real gaps for two weeks; revisit Option C if most gaps happen away from Wi-Fi. Verify the Assumptions on a real watch on watchOS 26.

## References

- [WKInterfaceDevice.batteryLevel](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel)
- [WKApplicationRefreshBackgroundTask](https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask)
- [scheduleBackgroundRefresh](https://developer.apple.com/documentation/watchkit/wkapplication/schedulebackgroundrefresh(withpreferreddate:userinfo:scheduledcompletion:))
- [Keeping your watchOS content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)
- [WCSession.remainingComplicationUserInfoTransfers](https://developer.apple.com/documentation/watchconnectivity/wcsession/remainingcomplicationuserinfotransfers)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Run shortcuts from Apple Watch](https://support.apple.com/guide/shortcuts/apd5888b0858/ios)
- [Forum 126286: CloudKit silent notifications on watchOS](https://developer.apple.com/forums/thread/126286)
