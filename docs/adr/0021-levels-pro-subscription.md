# ADR-0021: Levels Pro with StoreKit 2 on the device, no server, Mac free

- **Status:** Proposed
- **Date:** 2026-11-24
- **Deciders:** project owner
- **Related:** ADR-0003, ADR-0009, ADR-0013, ADR-0017, ADR-0019, ADR-0020, ADR-0022, MON-001, MON-002, REL-001, UI-003, NET-004, ALR-001, HIS-001

## Context

Levels started as a personal tool. Owner decisions N–Q (2026-11-24) make it a paid product:

- **N.** Build the subscription now and test it with local StoreKit testing. Enroll in the paid Apple Developer Program ($99/year) only at launch. At launch the paid account also turns on iCloud sync (SYNC-001) and ends the weekly reinstall.
- **O.** Freemium. Free: this device and its own accessories in the app, and one small widget. Pro: other devices (Mac hub now, iCloud later), every widget size and kind (Lock Screen, StandBy, medium, large), low-battery alerts and history.
- **P.** Monthly, yearly and lifetime. Suggested $0.99/month, $5.99/year with a 1-week free trial, $14.99 lifetime. One subscription group "Levels Pro". Family Sharing on.
- **Q.** iPhone (later iPad) ships in the App Store. The Mac app ships as a notarized direct download and stays unsandboxed (ADR-0022).

Forces:

- No backend (ADR-0019). Adding a server only to check receipts would add hosting, a privacy label entry and a thing to keep alive.
- Widgets run in an extension with a small time budget (ADR-0017). They must know "Pro or not" without network calls.
- The Mac app is outside the App Store. It can't sell App Store in-app purchases, and it is the hub that serves the iPhone (ADR-0020).
- There is no paid account yet. App Store Connect products can't be created until launch, so everything is built and tested against a local StoreKit configuration file.

### Facts (from Apple documentation; not re-checked on OS 26 hardware)

- StoreKit 2 transactions arrive as JWS signed by the App Store. `VerificationResult` gives `.verified` or `.unverified`; StoreKit checks the signature on the device. ([Transaction](https://developer.apple.com/documentation/storekit/transaction), [VerificationResult](https://developer.apple.com/documentation/storekit/verificationresult))
- `Transaction.currentEntitlements` lists the latest transaction for each active subscription and each non-consumable the user owns. Refunded (revoked) transactions are not in it. ([currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements))
- `Transaction.updates` delivers transactions that happen outside the purchase call: renewals, purchases on another device, Family Sharing, refunds and revocations. Apple says to start listening at launch. ([updates](https://developer.apple.com/documentation/storekit/transaction/updates))
- `Product.SubscriptionInfo.Status` has the states `subscribed`, `expired`, `inBillingRetryPeriod`, `inGracePeriod` and `revoked`. ([RenewalState](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate))
- `AppStore.sync()` forces a sync with the App Store and may ask the user to sign in. Apple says to call it only from a user action such as Restore Purchases. ([AppStore.sync()](https://developer.apple.com/documentation/storekit/appstore/sync()))
- Family Sharing is set per product in App Store Connect. Once turned on for a product it can't be turned off. ([Family Sharing](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases))
- Xcode's StoreKit testing runs purchases against a `.storekit` file with no App Store Connect account. The `StoreKitTest` framework (`SKTestSession`) drives the same file from unit tests: buy, renew, expire, refund, billing retry and grace period. ([Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode), [SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession))

Assumptions:

- **Assumption:** `currentEntitlements` includes a subscription in its billing grace period and leaves out one in billing retry without grace. MON-001 checks this with `SKTestSession` before relying on it.
- **Assumption:** a widget extension should not call StoreKit itself (time budget, and StoreKit in extensions is not a documented pattern for this). The widget reads a cache instead.
- **Assumption:** iOS has no public API for AirPods or other accessory battery levels. A free iPhone user therefore sees mostly the iPhone itself.

## Decision

**Levels Pro is sold only in the iPhone/iPad app, with StoreKit 2 and on-device verification. There is no server. The app writes the entitlement to the App Group so widgets can read it. The Mac app is free and has no paywall.**

1. **Products.** One subscription group "Levels Pro" with `com.tmatiashvili.levels.pro.monthly` and `com.tmatiashvili.levels.pro.yearly` (1-week free trial as an introductory offer), and the non-consumable `com.tmatiashvili.levels.pro.lifetime`. Family Sharing on for all three. Prices are read from StoreKit (`displayPrice`), never written in code.
2. **StoreKit 2 only.** No original StoreKit API, no receipt file parsing, no server and no App Store Server API. Only `.verified` transactions count. (Lead's call 33.)
3. **Who is entitled.** Pro is on when `currentEntitlements` holds a verified, non-revoked transaction for any of the three products. A subscription in its billing grace period counts. Billing retry without grace, expired and revoked do not.
4. **Listening.** The app starts one `Transaction.updates` listener at launch, before any UI, and finishes every transaction it handles. Refunds and revocations come through it (`revocationDate` set) and turn Pro off at once. Restore Purchases calls `AppStore.sync()`, then re-reads `currentEntitlements`. (Lead's call 35.)
5. **Cache in the App Group.** The app writes `entitlement.json` next to `snapshot.json` (ADR-0009) after every check. It holds the verified state, the product, the expiry and `verifiedAt`. Widgets read it and never call StoreKit. The cache is trusted only for a grace window: until the subscription's expiry (plus 3 days of offline slack), and never longer than 30 days after `verifiedAt`. After that the widget treats the user as free until the app checks again. The app re-verifies on launch, on foreground and in its background refresh. (Lead's call 33.)
6. **Where Pro is enforced.** On the iPhone/iPad only. The iPhone shows hub-synced or iCloud-synced devices, Pro widget families, alerts and history only when entitled. The iPhone still pairs and still reports its own battery to the Mac when free. (Lead's call 32.)
7. **The Mac is free.** No paywall, no StoreKit, no Pro check. The Mac can't sell App Store in-app purchases from outside the store, and it is the hub. It serves the full snapshot to every paired device whether that device is Pro or not. Mac alerts (ALR-001) and Mac history (HIS-001) stay free on the Mac. (Lead's call 32.)
8. **Paywall.** SwiftUI `SubscriptionStoreView` for the group, plus the lifetime product, with Restore Purchases, Terms and Privacy links and Manage Subscription (MON-002, lead's call 34).
9. **Module.** A new Shared module `LevelsPurchases` holds the StoreKit service; only `Levels-iOS` links it. The cache type `EntitlementSnapshot` and its reader live in `LevelsModel`, so widgets read it without linking StoreKit code. ADR-0003 gains the module when MON-001 is built.

## Options considered

### Option A — StoreKit 2 on the device, App Group cache, Mac free (chosen)
- Pros: no server and nothing new to disclose; Apple signs and verifies transactions; works offline; widgets stay fast; the Mac stays simple.
- Cons: a jailbroken device can edit the cache or patch the check. A modified iPhone client could read the Mac hub without Pro. The Mac shows every device for free.

### Option B — Own server validating transactions (App Store Server API)
- Pros: server-side truth; could enforce Pro on the Mac hub too.
- Cons: a backend to host and secure; breaks ADR-0019's "no server"; a privacy label entry; cost for a $0.99 product. Rejected.

### Option C — Third-party subscription SDK (RevenueCat or similar)
- Pros: dashboards, cross-platform entitlements.
- Cons: third-party code and a third party that receives purchase data; breaks ADR-0019 rule 2. Rejected.

### Option D — Sell Pro on the Mac too (Mac App Store)
- Pros: one purchase on every platform with universal purchase.
- Cons: the Mac App Store needs the sandbox, which blanks AirPods levels (ADR-0013, ADR-0015). A Developer ID app can't sell App Store in-app purchases. Rejected for now (ADR-0022).

### Option E — Widgets call StoreKit themselves
- Pros: always fresh.
- Cons: extra time in `getTimeline`; undocumented for extensions; no gain over a cache the app refreshes. Rejected.

## Consequences

- Positive: no backend; purchases work offline; the free/Pro line is one check in one place; the Mac and the hub need no change.
- Negative / accepted risks:
  - The cache is a convenience, not a security boundary. Someone who edits the App Group file can unlock widgets. Accepted: there is no server to check against.
  - The Mac hub serves everything to any paired device. A patched iPhone client gets Pro data for free. Accepted.
  - The Mac shows every device for free, so a user with a Mac may not need Pro. Pro sells the iPhone and iPad view.
  - A free iPhone user sees little more than the iPhone itself (no accessory API on iOS). MON-001 asks the owner whether one paired Mac should be free.
  - A Pro user who doesn't open the app or let it refresh for 30 days sees locked widgets until it runs again.
- Follow-ups: add `LevelsPurchases` to ADR-0003 and the Shared package; add `entitlement.json` to ADR-0009's file list; record the `SKTestSession` result for the grace-period assumption in MON-001.

## References

- [In-App Purchase (StoreKit 2)](https://developer.apple.com/documentation/storekit/in-app-purchase)
- [Transaction.currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements), [Transaction.updates](https://developer.apple.com/documentation/storekit/transaction/updates)
- [Product.SubscriptionInfo.RenewalState](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate)
- [AppStore.sync()](https://developer.apple.com/documentation/storekit/appstore/sync())
- [SubscriptionStoreView](https://developer.apple.com/documentation/storekit/subscriptionstoreview)
- [Setting up StoreKit testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode), [SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession)
- [Enable billing grace period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions)
- [Turn on Family Sharing for in-app purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases)
