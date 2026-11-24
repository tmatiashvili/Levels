---
id: MON-001
title: Levels Pro products and entitlements
milestone: launch      # owner decisions N–P
status: Draft
depends_on: [SYNC-002, NET-004, UI-003]
adrs: [3, 9, 17, 19, 21, 22]
targets: [Shared, Levels-iOS, Widgets-iOS, Levels-iOSTests]
---

# MON-001: Levels Pro products and entitlements

## Why

Levels Pro unlocks other devices, every widget kind, alerts and history on the iPhone (owner decision O). The app needs one honest answer to "is this person Pro right now?", in the app and in the widget, with no server (ADR-0021). This spec builds that answer. MON-002 builds the screens that sell Pro and the gates that use it.

## Scope

- In: the StoreKit configuration file and product IDs; `ProStore` (StoreKit 2 service); entitlement states and how each maps to Pro; the App Group cache `entitlement.json`; widget gating by family and content; the `ProGate` checks MON-002 uses; tests with `SKTestSession`.
- Out (and where it goes instead): paywall screens, copy and where gates appear → MON-002; App Store Connect setup → REL-001; Mac (free, no StoreKit) → ADR-0021 Decision 7; any server → never (ADR-0021).

## Behaviour

### Products

- **R1** Products (owner decision P). Prices are suggestions; the owner sets them in App Store Connect at launch.

  | Product ID | Type | Suggested price | Notes |
  |---|---|---|---|
  | `com.tmatiashvili.levels.pro.monthly` | auto-renewable, group "Levels Pro", level 2 | $0.99 / month | no trial |
  | `com.tmatiashvili.levels.pro.yearly` | auto-renewable, group "Levels Pro", level 1 | $5.99 / year | introductory offer: 1-week free trial, new subscribers only |
  | `com.tmatiashvili.levels.pro.lifetime` | non-consumable | $14.99 once | — |

  Family Sharing is on for all three (it can't be turned off later). The yearly plan is level 1 so moving monthly → yearly is an upgrade.
- **R2** A local StoreKit configuration file `Levels-iOS/Levels.storekit` holds the same three products, group and trial. The `Levels-iOS` scheme's Run action uses it (Options ▸ StoreKit Configuration). At launch the file is synced from App Store Connect and kept for tests (REL-001).
- **R3** The app never shows a hard-coded price. It uses `Product.displayPrice` and `Product.SubscriptionInfo.subscriptionPeriod`.

### Entitlement

- **R4** `ProStore` starts at launch, before the first view, and does three things: listens to `Transaction.updates` for the life of the process; handles `Transaction.unfinished`; reads `Transaction.currentEntitlements` once. It finishes every transaction it handles.
- **R5** Only `.verified` transactions count. An `.unverified` one is logged (category `store`, no personal data) and ignored, never finished as a purchase.
- **R6** States. `ProStore.state` is one of:

  | State | When | Pro? |
  |---|---|---|
  | `.unknown` | before the first read finishes | use the cache (R10) |
  | `.free` | no Pro transaction in `currentEntitlements` | no |
  | `.trial(expires:)` | yearly, `offer?.type == .introductory`, not expired | yes |
  | `.subscribed(product:, renews:, expires:)` | monthly or yearly, status `.subscribed` | yes |
  | `.gracePeriod(expires:)` | status `.inGracePeriod` (billing grace on in App Store Connect) | yes |
  | `.billingRetry` | status `.inBillingRetryPeriod`, grace over | no |
  | `.expired` | status `.expired`, or `expirationDate` in the past | no |
  | `.revoked` | `revocationDate` set (refund, Family Sharing removed) | no |
  | `.lifetime` | verified, non-revoked lifetime transaction | yes |

  If several apply (for example lifetime and a subscription), any "yes" wins and the state shows lifetime first, then subscription.
- **R7** Renewal, expiry, refund, revocation, Family Sharing changes and purchases on another device arrive through `Transaction.updates`. Each one re-runs the R6 read and updates the state at once. A revoked transaction turns Pro off at once, also mid-session.
- **R8** `isPro` is true for `.trial`, `.subscribed`, `.gracePeriod` and `.lifetime`. Nothing else in the app decides Pro.
- **R9** `ProStore` re-checks on launch, on every scene `.active`, and in the app's background refresh task (ADR-0011 `BGAppRefreshTask` and the "Report Battery" intent when it runs). A re-check is a local read; it never calls `AppStore.sync()`.

### Cache (App Group)

- **R10** After every R6 read the app writes `Levels/entitlement.json` in the App Group, atomically under `NSFileCoordinator` (same rules as `snapshot.json`, ADR-0009):

  ```json
  { "version": 1, "isPro": true, "kind": "yearly", "expiresAt": "2027-11-24T10:00:00Z", "verifiedAt": "2026-11-24T10:00:00Z" }
  ```

  `kind` is `monthly`, `yearly`, `lifetime` or `none`. `expiresAt` is null for lifetime and free. No transaction IDs, no Apple account data.
- **R11** **Trust window.** A reader treats the cache as Pro only while `now < trustedUntil`, where `trustedUntil = min(verifiedAt + 30 days, expiresAt + 3 days)` (lifetime: `verifiedAt + 30 days`). Past it, or if the file is missing, unreadable or a newer version, the reader treats the user as free. `verifiedAt` in the future (clock moved back) counts as `now`.
- **R12** At `.unknown` (R6) the app uses the cache by the R11 rule, so a Pro user doesn't see a locked flash on launch.
- **R13** When `isPro` changes, the app reloads all widget timelines once (not coalesced away by SYNC-001 R8a).

### Widget gating

- **R14** Families (owner decision O). The widget extension keeps every family in `supportedFamilies`, so the gallery shows all of them. Free users get:

  | Family / place | Free | Pro |
  |---|---|---|
  | `systemSmall` on the Home Screen | this device only | as UI-003 |
  | `systemSmall` in StandBy | locked view | as UI-003 |
  | `systemMedium`, `systemLarge` | locked view | as UI-003 |
  | `accessoryCircular`, `accessoryRectangular`, `accessoryInline` (Lock Screen) | locked view | as UI-003 |

  Free users may add as many small Home Screen widgets as they like; each shows this device.
- **R15** StandBy is detected in the view by `@Environment(\.showsWidgetContainerBackground) == false` on `systemSmall` (**Assumption:** true in StandBy and false on the Home Screen; checked on hardware, AC12).
- **R16** The locked view: the lock symbol, "Levels Pro", and one line "Open Levels to unlock" (accessory families: lock symbol and "Pro"). Tapping opens `levels://pro` (MON-002 R1). It follows UI-003 R9 rendering modes. It never shows another device's name or level.
- **R17** In the free small widget, `DeviceChoice` (UI-003 R1) offers only "This iPhone"; "Lowest battery" considers only this device. A Pro choice saved earlier that is no longer allowed falls back to this device.
- **R18** The widget decides only from `entitlement.json` (R11). It never links `LevelsPurchases` or StoreKit.

### Gate API for the app

- **R19** `ProGate` answers per feature: `.otherDevices`, `.widgetFamily(_:)`, `.alerts`, `.history`. Every answer is `isPro` today; the per-feature API exists so the owner's open question (one free Mac) changes one function, not the views.
- **R20** Device list filter: when not Pro, `DeviceListStore` keeps this device and its own accessories as normal rows, and turns every other device into a locked row (MON-002 R6). The iPhone still pairs, still syncs and still reports its own battery to the Mac (ADR-0021 Decision 6). Data is kept, not deleted, when Pro ends.

## Design

- **Module `LevelsPurchases`** (new, Shared package; linked by `Levels-iOS` only):

  ```swift
  public enum ProKind: String, Codable, Sendable { case monthly, yearly, lifetime, none }

  public enum ProState: Equatable, Sendable {
      case unknown, free, billingRetry, expired, revoked, lifetime
      case trial(expires: Date)
      case subscribed(kind: ProKind, renews: Bool, expires: Date)
      case gracePeriod(expires: Date)
      public var isPro: Bool { get }
  }

  public enum ProProductID {
      public static let monthly = "com.tmatiashvili.levels.pro.monthly"
      public static let yearly = "com.tmatiashvili.levels.pro.yearly"
      public static let lifetime = "com.tmatiashvili.levels.pro.lifetime"
      public static let subscriptionGroupName = "Levels Pro"
  }

  @MainActor @Observable
  public final class ProStore {
      public private(set) var state: ProState
      public private(set) var products: [Product]      // loaded with Product.products(for:)
      public init(entitlements: some EntitlementSource, cache: EntitlementCache, clock: some Clock<Duration>)
      public func start()                              // R4; idempotent
      public func refresh() async                      // R9
      public func purchase(_ product: Product) async throws -> PurchaseOutcome   // used by MON-002 for the lifetime button
      public func restore() async throws               // AppStore.sync() then refresh (MON-002 R10)
  }

  public protocol EntitlementSource: Sendable {        // seam: StoreKit in the app, a fake in unit tests
      func currentTransactions() async -> [VerifiedPurchase]
      func updates() -> AsyncStream<VerifiedPurchase>
      func subscriptionStatus() async -> [SubscriptionStatusSnapshot]
  }
  ```

  `VerifiedPurchase` and `SubscriptionStatusSnapshot` are plain value types copied out of `Transaction` and `Product.SubscriptionInfo.Status`, so the R6 mapping is a pure function: `ProState.from(purchases:statuses:now:)`.
- **`LevelsModel`**: `EntitlementSnapshot` (the R10 JSON, `Codable`, `Sendable`), `EntitlementCache` (read and write, same file rules as `SnapshotCache`) and `EntitlementSnapshot.isTrusted(now:)` (R11). Widgets use only these.
- **`LevelsWidgetKit`**: `DevicesProvider` reads `EntitlementSnapshot` and picks content per R14–R17; `ProLockedView` (R16).
- **`LevelsUI`**: `ProGate` (R19) and the `DeviceListStore` filter (R20) take `isPro` as input, so they don't link StoreKit.
- Concurrency: `ProStore` is `@MainActor`; the `Transaction.updates` loop runs in a `Task` it owns and hops to the main actor to set `state`. Types crossing actors are `Sendable` values.
- Entitlements and Info.plist: StoreKit needs no entitlement. The In-App Purchase capability is added in Xcode at launch (REL-001).
- Logs: category `store`; product kind and state only, never transaction IDs or Apple account data (ADR-0019 rule 3).
- **Builder's call:** whether `subscriptionStatus()` uses `Product.SubscriptionInfo.status(for: groupID)` or each transaction's `subscriptionStatus`; how the background task schedules the re-check.

## Edge cases and failure modes

- **Offline at launch:** `currentEntitlements` still answers from the device's copy. If it is empty and the cache says Pro within R11, show Pro until the next good read says otherwise.
- **Clock moved forward:** a subscription may look expired early; the next read with the right clock fixes it. Moved back: R11 treats a future `verifiedAt` as now.
- **Refund of lifetime:** `revocationDate` set → `.revoked` → free, widgets reload (R7, R13).
- **Family member leaves the family:** the shared transaction is revoked → free.
- **Upgrade monthly → yearly mid-period:** the App Store switches at once and marks the old transaction `isUpgraded`; the mapping skips upgraded transactions and reads the new one, so `isPro` stays true.
- **Lifetime bought while subscribed:** Pro stays on; MON-002 tells the user to cancel the subscription (MON-002 R11).
- **Ask to Buy (child):** purchase is `.pending`; state stays free until approved through `Transaction.updates`.
- **Free trial already used:** StoreKit hides the trial (`isEligibleForIntroOffer == false`); MON-002 shows the plain price.
- **App Group missing (free-team build without it):** the widget treats the user as free; the app still works.
- **Two Apple Accounts on one device:** StoreKit answers for the signed-in account; the cache follows on the next read.

## Acceptance criteria

- [ ] AC1 — Given `Levels.storekit`, then it holds exactly the three R1 products, one group "Levels Pro", the yearly 1-week trial and Family Sharing on all three.
- [ ] AC2 — Given each row of the R6 table (built from fake purchases and statuses), then `ProState.from` returns that state and `isPro` matches the table (unit test, one case per row).
- [ ] AC3 — Given an `.unverified` transaction, then the state stays `.free` and it is not finished as a purchase (R5).
- [ ] AC4 — `SKTestSession`: buy yearly → `.trial`; let the trial run out with renewal on → `.subscribed`; expire → `.expired` (R6, R7).
- [ ] AC5 — `SKTestSession`: buy monthly, then refund it → `.revoked` and `entitlement.json` says `isPro: false` within one update (R7, R10).
- [ ] AC6 — `SKTestSession` with billing grace period on and renewal failing: state `.gracePeriod`, `isPro` true; after grace ends: `.billingRetry`, `isPro` false. The result for ADR-0021's grace-period assumption is recorded here.
- [ ] AC7 — `SKTestSession`: buy lifetime → `.lifetime`; refund → `.revoked` (R6).
- [ ] AC8 — Given a cache with `verifiedAt` 31 days ago and `isPro: true`, then `isTrusted` is false; 29 days ago and no expiry passed, then true; `expiresAt` 4 days ago, then false (R11).
- [ ] AC9 — Given state `.unknown` and a trusted Pro cache, then the list shows Pro rows with no locked flash (R12).
- [ ] AC10 — Given `isPro` changes, then widgets reload once (R13; fake `WidgetCenter`).
- [ ] AC11 — Given a free cache, then `systemMedium`, `systemLarge` and every accessory family render the locked view, and `systemSmall` on the Home Screen renders this device only; given a Pro cache, all render as UI-003 (R14, R16, R17; provider tests and previews).
- [ ] AC12 — On real hardware: a free `systemSmall` widget shows the locked view in StandBy and this device on the Home Screen (R15).
- [ ] AC13 — Given not Pro and a hub snapshot with a Mac and AirPods, then the store shows this iPhone as a normal row and the Mac and AirPods as locked rows, and the iPhone still reports its own battery (R20).
- [ ] AC14 — Log check: no transaction ID or account data in category `store` (Design).

## Tests

- Unit (Swift Testing, `LevelsPurchases` and `LevelsModel` package tests): the R6 mapping (AC2, AC3), the trust window (AC8), store filter and gate (AC13), widget provider (AC11) — all against fakes, no simulator.
- StoreKit integration (`Levels-iOSTests`, hosted in `Levels-iOS`, `import StoreKitTest`): `SKTestSession(configurationFileNamed: "Levels")`, `disableDialogs = true`, `clearTransactions()` before each test, `timeRate` sped up for renewals; `buyProduct`, `expireSubscription`, `refundTransaction`, `billingGracePeriodIsEnabled` and a failing renewal (AC4–AC7). **Assumption:** these are the `SKTestSession` member names on OS 26; the builder checks the StoreKitTest docs and adjusts the test, not the behaviour.
- Previews: locked view in every family and rendering mode.
- Real hardware: AC12. Sandbox purchases with a Sandbox Apple Account only after enrollment (REL-001).

## Open questions

1. **Free tier is thin on the iPhone.** iOS has no public API for AirPods or other accessory levels, so "this device and its accessories" means only the iPhone itself on an iPhone. Options:
   - (a) As decided: free shows the iPhone only; everything from the Mac is Pro.
   - (b) Free also shows one paired Mac's own battery; its accessories, other devices, Pro widgets, alerts and history stay Pro. **Lead's recommendation:** gives a free user a reason to pair and keep the app, and still leaves the main value in Pro.
   - (c) Free shows one paired Mac and its accessories; Pro is widgets, alerts, history and iCloud devices.
   `ProGate` (R19) makes any of these a one-function change.
2. **"One small widget"** is read as "the small Home Screen widget, any number of copies, this device only". Limiting it to one copy would need counting configurations and is easy to get wrong. Confirm.
3. **StandBy** uses the same small widget. R15 locks it there for free users. Confirm that StandBy should be Pro.
4. **The Mac shows everything for free**, including the iPhone's battery (ADR-0021 consequences). Confirm that's fine.
5. **Prices and trial:** confirm $0.99 / $5.99 with a 1-week trial / $14.99, trial on yearly only.
