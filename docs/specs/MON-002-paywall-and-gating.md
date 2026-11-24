---
id: MON-002
title: Levels Pro paywall and gates
milestone: launch      # owner decisions N–P
status: Draft
depends_on: [MON-001, UI-001, UI-002, UI-003, NET-004]
adrs: [16, 19, 21, 22]
targets: [Shared, Levels-iOS, Widgets-iOS]
---

# MON-002: Levels Pro paywall and gates

## Why

People need to see what Pro adds, what it costs and how to stop paying, in plain words, at the moment they reach for a Pro feature. App Review also has firm rules for subscription screens (guidelines 3.1.1 and 3.1.2). This spec defines the paywall, every place a gate appears, restore and manage, and what we never do.

## Scope

- In: the paywall sheet and its copy; Settings ▸ Levels Pro; locked device rows; widget configuration and locked widgets (screens; logic is MON-001); Alerts and History gates on the iPhone; Restore Purchases; Manage Subscription; App Review disclosures; no dark patterns.
- Out (and where it goes instead): entitlement logic, states, cache → MON-001; App Store Connect metadata, Terms and Privacy URLs → REL-001; the text of the legal pages → `docs/legal/`; iPhone alerts and iPhone history themselves → later specs (ALR-001 and HIS-001 are Mac-only today); the Mac → no paywall (ADR-0021 Decision 7).

## Behaviour

### When the paywall shows

- **R1** The paywall is a sheet. It opens only when the user taps something Pro: a locked row (R6), a locked widget (`levels://pro`, MON-001 R16), the Alerts or History gate (R8), or Settings ▸ Levels Pro (R12). Never on launch, never on a timer, never after pairing, never more than once per tap.
- **R2** The sheet has a close button (top trailing, `xmark`, label "Close") that is visible and works from the first frame. Swipe down also closes it.

### Paywall content

- **R3** Top to bottom:
  1. Title **"Levels Pro"**. Subtitle **"All your devices, on your iPhone."**
  2. Four lines, each with an SF Symbol:
     - `laptopcomputer.and.iphone` "See your Mac, AirPods and other devices"
     - `square.grid.2x2` "Every widget: Lock Screen, StandBy, medium and large"
     - `bell.badge` "Low-battery alerts"
     - `chart.xyaxis.line` "7-day battery history"
  3. Plans (R4).
  4. The disclosure text (R5).
  5. Links: **Restore Purchases**, **Terms of Use**, **Privacy Policy**.
- **R4** Plans, using `SubscriptionStoreView(groupID:)` for monthly and yearly and a separate row for lifetime (Design):

  | Plan | Main line (largest) | Second line |
  |---|---|---|
  | Yearly, trial eligible | "1 week free, then $5.99 per year" | "Auto-renews yearly. Cancel anytime." |
  | Yearly, not eligible | "$5.99 per year" | "Auto-renews yearly. Cancel anytime." |
  | Monthly | "$0.99 per month" | "Auto-renews monthly. Cancel anytime." |
  | Lifetime | "$14.99 once" | "One payment. No subscription." |

  Prices and periods come from StoreKit (MON-001 R3); the table shows US English with the suggested prices. The billed amount and period are always the largest price text. A per-month figure for yearly ("$0.50 a month") may appear only smaller, under the billed amount, or not at all. Yearly is selected by default and the selection is clearly visible; nothing is pre-ticked beyond that.
- **R5** Disclosure text, shown above the buy button, always visible without tapping:

  > Payment is charged to your Apple Account when you confirm. Subscriptions renew automatically unless you turn off auto-renew at least 24 hours before the end of the current period. Your account is charged for the renewal within 24 hours before the period ends. Manage or cancel in Settings ▸ [your name] ▸ Subscriptions. If you start a subscription during the free trial, the rest of the trial ends. Lifetime is a one-time purchase.

- **R6** Buy button text follows the selection: "Start free week" (yearly, eligible), "Subscribe" (monthly, yearly not eligible), "Buy for $14.99" (lifetime). After a purchase: the sheet shows "You have Levels Pro" with a check mark for 1 s and closes; the locked items unlock in place.

### Where gates appear

- **R7** **Device list (locked rows).** When not Pro, devices other than this one (MON-001 R20) show as locked rows: device symbol, name, `lock.fill`, and the trailing text "Pro". No level, no ring, no age. VoiceOver: "<name>, locked. Levels Pro shows its battery." Tap opens the paywall. The rows sit in their normal UI-001 order. At most one section footer: "Levels Pro shows every device from your Mac."
- **R8** **Alerts and History (iPhone Settings).** Rows "Low-battery alerts" and "History" show a "Pro" tag when not Pro. Tap opens the paywall. When Pro, they open their screens (later specs). Nothing about alerts or history on the Mac changes.
- **R9** **Widget configuration.** When not Pro, the small widget's device picker offers "This iPhone" only (MON-001 R17). Locked widgets (MON-001 R16) say "Open Levels to unlock" and open the paywall. The widget gallery description for each Pro family ends with "Requires Levels Pro." (set in `.description`).

### Restore and manage

- **R10** **Restore Purchases** on the paywall and in Settings ▸ Levels Pro calls `ProStore.restore()` (`AppStore.sync()`, then re-read). It shows a spinner, then one of: "Levels Pro restored.", "No purchases found for this Apple Account.", or "Couldn't reach the App Store. Try again." It never runs without a tap (it may ask the user to sign in).
- **R11** **Settings ▸ Levels Pro** (top of the Settings sheet):
  - Free: "Levels Pro" row → paywall; **Restore Purchases**.
  - Trial: "Free trial · ends <date>" and "Then $5.99 per year". **Manage Subscription**.
  - Subscribed: "Yearly" or "Monthly", "Renews <date>" or "Ends <date>" if auto-renew is off. **Manage Subscription**.
  - Grace period: "Payment problem · Pro until <date>" and **Manage Subscription**. Same text in a one-line banner on the list once per day.
  - Billing retry or expired: "Levels Pro ended" and the "Levels Pro" row.
  - Lifetime: "Lifetime · thank you". If a subscription is also active: "You also have an active subscription. You can cancel it in Manage Subscription." and **Manage Subscription**.
  - Shared by family: adds "Shared by your family".
  **Manage Subscription** opens `.manageSubscriptionsSheet(isPresented:)`.
- **R12** When Pro ends, nothing is deleted. Locked rows return, Pro widgets show the locked view, alerts stop, history keeps recording on the device for 7 days but is hidden. Coming back to Pro shows everything again.

### Never (no dark patterns)

- **R13** The app never: shows the paywall without a tap (R1); hides or delays the close button; uses countdown timers or fake "limited time" offers; uses shaming text on the close or decline path; pre-selects lifetime or hides the cheaper plans; shows a price smaller than a per-month figure; makes cancel harder than subscribing; asks for an App Store rating on the paywall; shows the paywall to a user who is already Pro; mentions buying anywhere other than the App Store.

## Design

- `Levels-iOS`: `ProPaywallView` wraps
  ```swift
  SubscriptionStoreView(groupID: proGroupID) { ProMarketingHeader() }   // R3 items 1–2
      .subscriptionStoreControlStyle(.picker)
      .subscriptionStoreButtonLabel(.multiline)
      .storeButton(.visible, for: .restorePurchases)
      .storeButton(.visible, for: .policies)
      .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
      .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
  ```
  The lifetime product is a `ProductView(id: ProProductID.lifetime)` below the subscription picker, inside the same scroll view. **Assumption:** `SubscriptionStoreView` can't show a non-consumable in its own picker; if a single custom picker reads better, the builder may replace both with a custom view built on `Product` and `product.purchase()`, keeping R4–R6.
- **Builder's call:** whether the system's own subscription text covers R5 on OS 26. If it shows all of R5's points, don't repeat them; if any point is missing, add R5 under the store view. App Review screenshot check in REL-001 decides.
- `termsURL` and `privacyURL` are constants filled in at launch (REL-001 R8). Until then they point to placeholders and the paywall shows them as links.
- `LevelsUI`: `LockedDeviceRow` (R7) and a `ProTag` view used by R7 and R8. Both take `isPro` from `ProGate` (MON-001 R19).
- `levels://pro` is handled by the app's URL handler and opens the paywall sheet (R1).
- Strings live in the string catalog; this spec's texts are the English source. Prices are never part of a translated string; they are interpolated from StoreKit.
- Accessibility: Dynamic Type up to AX5 without cutting the disclosure; every plan readable by VoiceOver as "Yearly, 1 week free, then $5.99 per year, auto-renews"; colour is never the only sign of "locked" (the lock symbol and "Pro" text carry it).

## Edge cases and failure modes

- **Products fail to load** (offline, App Store down): the paywall shows "Can't load prices right now." and **Try again**; no buy button without a real price.
- **Purchase cancelled by the user:** sheet stays, no message.
- **Purchase pending (Ask to Buy):** "Waiting for approval. Levels Pro turns on when it's approved." and the sheet can close.
- **Purchase fails:** "The purchase didn't go through. You weren't charged." and the sheet stays.
- **Already Pro** and `levels://pro` opens: show Settings ▸ Levels Pro instead (R13).
- **Locked row tapped while offline:** the paywall opens and follows the "fail to load" case.
- **Trial already used on this Apple Account:** yearly shows the plain price (R4 row 2).

## Acceptance criteria

- [ ] AC1 — Given launch, pairing or any background event, then the paywall never opens; it opens only from the R1 taps (UI test).
- [ ] AC2 — Given the paywall, then the close button is hittable at once and closes the sheet (UI test).
- [ ] AC3 — Given the local StoreKit file, then each plan shows the R4 lines with StoreKit's prices, the billed amount is the largest price text, and yearly is selected (preview and UI test).
- [ ] AC4 — Given a trial-eligible account, then yearly says "1 week free, then <price> per year"; given not eligible, then only the price (R4; `SKTestSession` after a used trial).
- [ ] AC5 — Given the paywall, then the R5 points (charge on confirm, auto-renew, 24-hour rule, how to cancel, trial ends on purchase) are all visible without scrolling past the buy button on an iPhone SE-size screen at default text size (screenshot check).
- [ ] AC6 — Given the paywall, then Restore Purchases, Terms of Use and Privacy Policy are visible and each works (UI test; links open the URLs).
- [ ] AC7 — Given not Pro and a Mac in the snapshot, then the Mac shows as a locked row with no level; VoiceOver reads the R7 label; tap opens the paywall (R7).
- [ ] AC8 — Given not Pro, then Alerts and History rows show "Pro" and open the paywall (R8).
- [ ] AC9 — Given each R11 state (fake `ProStore`), then Settings ▸ Levels Pro shows the matching text and buttons (previews and unit test).
- [ ] AC10 — Given Restore with no purchases, a lifetime purchase, or no network, then the matching R10 message shows (`SKTestSession` and a fake).
- [ ] AC11 — Given Pro ends, then no device data or history file is deleted, and buying again shows it all (R12).
- [ ] AC12 — Given products fail to load, then no buy button shows and Try again reloads (edge cases).
- [ ] AC13 — Review against R13 before submission: a checklist pass recorded in REL-001.

## Tests

- Unit: settings state mapping (AC9), restore outcomes (AC10), store filter (AC7, AC11) against fakes.
- UI tests (`Levels-iOSTests` with the `.storekit` file): AC1–AC4, AC6, AC8, AC12.
- Previews: paywall in light, dark, AX5; every R11 state; locked rows.
- Manual: AC5 screenshot, AC13 checklist, VoiceOver pass.

## Open questions

1. **Copy.** The subtitle and four feature lines are a first draft. If the owner picks MON-001 open question (b) or (c), the first feature line changes (for example "See every device, not just your Mac").
2. **Default plan.** Yearly with the trial is selected by default. Confirm, or prefer no default.
