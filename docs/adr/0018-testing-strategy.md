# ADR-0018: Test logic with Swift Testing behind protocol seams, test the platform by hand on real devices, run CI locally for v0.1

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0003, ADR-0004, ADR-0007, ADR-0008, ADR-0010, ADR-0011, ADR-0017, ADR-0019, QA-001

## Context

Most of Levels' risk sits in platform behaviour we don't control: background execution, push delivery, widget reload budgets and battery APIs. The logic we do control (merging records, throttling writes, deciding what is stale, formatting "updated X min ago") is small and easy to test, but only if it doesn't call CloudKit or hardware directly.

Facts (verified):

- A silent (background) push is low priority. "The system doesn't guarantee their delivery", may throttle them, and Apple says not to send "more than two or three per hour". The system keeps only the newest held notification, and drops it if the app is force-quit. ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app))
- CloudKit coalesces subscription notifications: "don't rely on them for specific changes". ([CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription))
- Widget reloads use a daily budget, typically 40–70 refreshes for a widget the user views often, "roughly … every 15 to 60 minutes". Reloads don't count against the budget while the containing app is in the foreground. ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)) So a test with the app open measures nothing useful.
- `UIDevice.batteryLevel` is –1.0 and the state is `unknown` when monitoring is off. ([batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel))
- CloudKit has a Development and a Production environment. Store apps use only Production. Schema must be deployed from Development to Production in CloudKit Console; deployment is additive, and fields or record types already in Production can't be deleted. ([Deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema))
- Xcode Cloud includes 25 compute hours a month with the Apple Developer Program; unused hours don't roll over. ([Apple news](https://developer.apple.com/news?id=ik9z4ll6), [Xcode Cloud](https://developer.apple.com/xcode-cloud/get-started))

Assumptions (not verified against Apple documentation):

- **Assumption:** the iOS Simulator reports battery level as unknown (–1) even with monitoring on, and has no way to simulate charging. Widely reported; not documented.
- **Assumption:** Shortcuts personal automations ("When battery level rises above / falls below") can't be triggered on the Simulator.
- **Assumption:** the Simulator can receive pushes sent with `xcrun simctl push`, but this doesn't prove CloudKit-triggered APNs delivery or throttling behaviour on a real device.
- **Assumption:** GitHub-hosted macOS runners are billed at a higher per-minute rate than Linux for private repos, and the newest Xcode/OS 26 SDK can lag on hosted images.
- **Assumption:** builds signed for TestFlight, the App Store and Developer ID use the Production CloudKit environment by default; Xcode debug builds default to Development unless the entitlement says otherwise. Forum reports say TestFlight defaults to Production. ([forum thread 842909](https://developer.apple.com/forums/thread/842909))

## Decision

Test what we own automatically, and test what Apple owns by hand on real devices with recorded numbers.

1. **Unit tests use Swift Testing** (`import Testing`, `@Test`, `#expect`) in the `Shared` package. They run with `swift test` or `xcodebuild test` and need no device, account or network. No XCTest for new unit tests; XCTest only for UI tests if we add any.
2. **Protocol seams.** `Shared` code never calls the platform directly. It depends on small protocols, each with a live implementation in the app target or `Shared`, and an in-memory fake in a test-support target:
   - `BatteryReader` — returns a reading (level, charging, low power). Owned by ADR-0010; tests use a scripted fake.
   - `CloudDatabase` — the subset of `CKDatabase`/`CKContainer` we use: account status, save/fetch records, fetch zone changes, modify zones, save subscriptions. Shape defined in SYNC-001. The fake is an in-memory dictionary that can inject `CKError` codes (`networkUnavailable`, `serverRecordChanged`, `notAuthenticated`, `quotaExceeded`, `zoneNotFound`, `requestRateLimited` with `retryAfterSeconds`).
   - Account status and account changes go through `CloudDatabase.accountStatus()` and the `CKAccountChanged` notification (SYNC-001); no separate protocol.
   - A `Clock` (Swift's `Clock` protocol) for the write throttle (ADR-0008) and staleness (ADR-0017), so tests don't sleep.
   - `SnapshotCache` for the App Group cache (ADR-0009, SYNC-002); tests use `SnapshotCache(directory:)` on a temporary directory.
   - The `widgetReloader` closure passed to `BatterySyncService` (SYNC-001) wraps `WidgetCenter.shared.reloadAllTimelines()` so tests can count reload calls.
3. **What needs a test.** Every spec's acceptance criteria say which are unit tests. At minimum: record ↔ model mapping, merge and conflict rules, write throttle, staleness thresholds, relative-time text, cache read/write, account-change handling, "Remove all my data" (ADR-0019) against the fake.
4. **Real-device manual tests** cover everything the Simulator can't: battery readings, charging transitions, silent push arrival, widget update latency, Shortcuts automations, Mac sleep, iCloud sign-out. They live in `docs/specs/QA-*.md` as numbered cases with expected results and a place to record observed minutes. QA-001 covers v0.1 and QA-002 covers v0.2. Each milestone adds or extends a QA spec. A milestone isn't done until its QA run is recorded (date, devices, OS build, pass/fail, observed numbers).
5. **CI: local only for v0.1, unless SPIKE-001 fails.** A single script (for example `scripts/test.sh`) runs `swift test` for `Shared` and builds every scheme. Run it before every merge to `main`. Set up CI when the first TestFlight build is needed, and prefer **Xcode Cloud** (included hours, handles signing and TestFlight upload) over GitHub Actions. Owner decision (2026-11-23): Debug builds use `aps-environment = development` (a development profile allows nothing else); Release, TestFlight and Developer ID use `production`; the CloudKit container environment is Production in all of them (§6). [SPIKE-001](../specs/SPIKE-001-debug-build-push-check.md), the first v0.1 item, checks on a real iPhone that a Debug build still gets the database-subscription silent push. **If it passes**, the owner uses Xcode debug builds daily and Xcode Cloud waits for the first TestFlight need. **If it fails**, the owner's daily iPhone build comes from TestFlight, so Xcode Cloud (archive, sign, upload to TestFlight) is set up at the start of v0.1, before RPT-001 and QA-001 need a push-receiving iPhone build.
6. **CloudKit environments.** Owner decision (2026-11-23): every daily build, including Xcode debug builds, uses the Production environment (`com.apple.developer.icloud-container-environment = Production` in every target's entitlements, ADR-0005 rule 5). Experiments (throwaway subscriptions, integration tests, schema trials) use a separate container or test setup, never the daily Production data. Before the first build, and before any build that adds fields, the owner runs "Deploy Schema Changes" in CloudKit Console. This is a checklist step in QA-001 and in any release notes. Because Production is additive-only, schema fields are reviewed (ADR-0005) before the first deploy. Indexes needed by queries and subscriptions (ADR-0006) must exist in Production; check them in Console after deploying.

## Options considered

### Option A — Swift Testing + seams + manual device checklist + local CI (chosen)
- Pros: fast tests with no iCloud; no CI cost or setup now; manual checklist matches where the real risk is; numbers recorded give evidence for later tuning.
- Cons: relies on discipline to run the script; manual runs take time on each milestone; no automated signal on regressions in platform behaviour.

### Option B — Xcode Cloud from day one
- Pros: 25 free hours a month; runs tests on every push; can upload to TestFlight; Apple keeps Xcode current.
- Cons: setup and signing work before there's anything to ship; still can't test battery, push or widgets; one-person project gets little from it yet.

### Option C — GitHub Actions macOS runners
- Pros: familiar YAML; works if the repo lives on GitHub.
- Cons: **Assumption:** higher macOS minute cost; Xcode 26 availability on hosted images can lag; signing secrets to manage; same platform blind spots as B.

### Option D — Integration tests against the real CloudKit Development environment
- Pros: exercises the real server, indexes and errors.
- Cons: needs a signed-in iCloud account on the test machine; slow and flaky; pollutes test data. Keep it as a manual step in QA specs, against a separate test container (Decision 6), not an automated suite.

## Consequences

- Positive: sync, throttle and staleness logic can be built and tested before the Mac or iPhone app exists. Fakes make error paths (no account, rate limit, zone missing) easy to test.
- Negative / accepted risks: platform regressions (for example a new OS throttling pushes harder) are only caught in manual runs. Observed widget latency is a sample, not a guarantee.
- Follow-ups: run SPIKE-001 first; add `scripts/test.sh` with the project skeleton (ADR-0003); set up Xcode Cloud before the first TestFlight build (at the start of v0.1 if SPIKE-001 fails, §5); each later milestone adds a QA spec.

## References

- [Swift Testing](https://developer.apple.com/xcode/swift-testing/)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [UIDevice.batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel)
- [Deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
- [Xcode Cloud: get started](https://developer.apple.com/xcode-cloud/get-started), [25 hours included](https://developer.apple.com/news?id=ik9z4ll6)
