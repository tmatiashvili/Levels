---
id: SPIKE-001
title: Debug-build silent push check (Production CloudKit container)
milestone: v0.1
status: Draft
depends_on: []
adrs: [5, 6, 13, 18]
targets: [Levels-iOS, Levels-Mac]
---

# SPIKE-001: Debug-build silent push check (Production CloudKit container)

## Why

Every daily build uses the Production CloudKit container (ADR-0005 rule 5), but a Debug build is signed with a development profile, which only allows `aps-environment = development`. We don't know whether such a build receives the database-subscription silent push that CloudKit sends for Production data. The answer decides where the owner's daily iPhone build comes from, so it is checked first, in about 30 minutes, before any other v0.1 work.

## Scope

- In: a throwaway iPhone Debug build and a throwaway Mac build that save one subscription and one record in the Production container; one real-device test; a written result.
- Out (and where it goes instead): the real sync service (SYNC-001); the real Mac agent (MAC-001); push latency numbers (QA-001 QA1-20, QA1-24). The spike code is not kept.

## Behaviour

Owner decision (2026-11-23) on push environments:

| Build | `aps-environment` / `com.apple.developer.aps-environment` | `com.apple.developer.icloud-container-environment` |
|---|---|---|
| Debug (Xcode, development profile) | `development` | `Production` |
| Release, TestFlight, Developer ID | `production` | `Production` |

- **R1** — The iPhone runs a Debug build installed from Xcode with the entitlements above, the real container ID (`iCloud.<rdns>.levels`), `UIBackgroundModes = [remote-notification]`, and `registerForRemoteNotifications()` at launch. It saves `CKDatabaseSubscription("levels-private-db")` with `shouldSendContentAvailable = true` (as SYNC-001 R3) and logs every `didReceiveRemoteNotification` with a timestamp and the subscription ID.
- **R2** — The Mac runs any build (Debug is fine) that writes a `DeviceBattery` record into the `Levels` zone of the Production container on a button press. The schema must already be deployed (ADR-0018 §6).
- **R3** — Test: iPhone app installed from Xcode, then launched from the Home Screen (not from Xcode) and sent to the background (not force-quit) with no debugger attached, screen locked. Press the Mac button 3 times, at least 5 minutes apart. Read the iPhone log afterwards.
- **R4** — **Pass:** at least one silent push for `levels-private-db` arrives on the iPhone within 5 minutes of a Mac write. **Fail:** none of the 3 writes produces a push, while a TestFlight build of the same iPhone code (`production`) does receive one under the same conditions. If the TestFlight build also gets nothing, the result is **Blocked**: the setup is wrong (schema, subscription, background mode), not the push environment.
- **R5** — **On Pass:** the owner keeps Xcode debug builds for daily use; Xcode Cloud waits for the first TestFlight need (ADR-0018 §5).
- **R6** — **On Fail:** the owner's daily iPhone build comes from TestFlight. Xcode Cloud (archive, sign, TestFlight upload) is set up at the start of v0.1 (ADR-0018 §5), and QA-001 runs the iPhone on a TestFlight build. Debug builds keep `development` and are used only for work that doesn't need pushes.
- **R7** — The result (Pass, Fail or Blocked, date, devices, OS builds, push times) is written at the end of this file and added to [decisions-log.md](../decisions-log.md).

## Design

No production code. A single-screen iOS app and a single-button Mac app, or a scratch branch of the real targets, whichever is quicker. Use the real bundle IDs and container so the entitlements match the daily builds. Delete the test record afterwards in CloudKit Console.

## Edge cases and failure modes

- Silent pushes are best effort and can be throttled (ADR-0018 facts). Three writes 5 minutes apart stay under Apple's "two or three per hour" only loosely; one received push is enough for Pass, and zero with a working TestFlight control is Fail.
- Xcode attached keeps the app alive and can hide problems; detach the debugger before R3.
- Low Power Mode or Focus can delay background work; turn both off.

## Acceptance criteria

- [ ] AC1 — Given the R1 iPhone Debug build and the R2 Mac build on the Production container, when the Mac writes 3 times (R3), then the result is recorded as Pass, Fail or Blocked by R4, with push timestamps.
- [ ] AC2 — Given the result, then ADR-0018 §5's branch (R5 or R6) is chosen and the decisions log has a dated row.

## Tests

Manual on real hardware: one iPhone and one Mac signed into the owner's Apple ID. The Simulator can't show CloudKit push delivery (ADR-0018).

## Open questions

- None. The outcome is a measurement; both branches are already decided (R5, R6).

## Result

(Fill in after the run.)
