---
id: REL-001
title: App Store and Mac download readiness
milestone: launch      # owner decisions N, Q
status: Draft
depends_on: [MON-001, MON-002, SYNC-001, NET-004]
adrs: [13, 19, 20, 21, 22]
targets: [Levels-iOS, Widgets-iOS, Levels-Mac, Widgets-Mac]
---

# REL-001: App Store and Mac download readiness

## Why

Launch needs many small things done in the right order, most of them outside the code: an account, store records, legal pages, privacy answers, screenshots, a signed Mac download. Missing one means a rejected build or a Mac app Gatekeeper won't open. This spec is the checklist. Each item is a rule a person can tick.

## Scope

- In: paid account steps; App Store Connect setup; the three Pro products; privacy manifests and App Privacy answers; Info.plist keys; export compliance; age rating; screenshots; review notes; TestFlight; Mac signing, notarization and the download; version and build numbers.
- Out (and where it goes instead): entitlement code → MON-001; paywall → MON-002; legal text → `docs/legal/`; CloudKit cut-over → SYNC-001 and ADR-0020 Decision 12.

## Behaviour

### Now, on the free team (owner decision N)

- **R1** Before enrollment, these are done and checked in: `Levels.storekit` (MON-001 R2); `PrivacyInfo.xcprivacy` in every target (R5); the Info.plist keys (R6); `ITSAppUsesNonExemptEncryption` (R9); legal drafts reviewed by the owner (R8); screenshots taken from the simulator (R11).

### Account and App Store Connect (at launch)

- **R2** **Account.**
  1. Enroll in the Apple Developer Program as an individual ($99/year). The App Store shows the owner's legal name as the seller.
  2. Fill in the bundle ID root (`<rdns>`, owner decision B) and the paid Team ID; update SETUP.md's App Group and keychain group IDs.
  3. Sign the Paid Applications Agreement; add tax and banking in App Store Connect ▸ Business. Products can't be sold until these are active.
  4. Apply to the App Store Small Business Program (15% commission instead of 30%).
- **R3** **App record.** Platform iOS; name "Levels" (**Assumption:** the name is free on the App Store; if not, pick one at this step, for example "Levels: Battery Widgets"); primary language English (U.S.); bundle ID `<rdns>.levels`; SKU `levels-ios`; primary category Utilities; subtitle (30 characters max), keywords, description, support URL, marketing URL (optional), privacy policy URL (R8).
- **R4** **Products** (MON-001 R1).
  1. Subscription group "Levels Pro" with its localized display name.
  2. Monthly and yearly: reference name, product ID, duration, price, localized name and description, review screenshot of the paywall, review notes.
  3. Yearly introductory offer: free, 1 week, new subscribers.
  4. Lifetime non-consumable with the same fields.
  5. Family Sharing on for all three (it can't be undone).
  6. Billing grace period on (16 days for all renewals; **Builder's call:** 3 or 16 days, 16 preferred for low prices).
  7. Sync `Levels.storekit` from App Store Connect in Xcode afterwards, so local tests match the store.
  8. The first subscription and the lifetime product are submitted with the first app version.

### Privacy

- **R5** **Privacy manifests** (ADR-0019 Decision 4). Each of `Levels-iOS`, `Widgets-iOS`, `Levels-Mac`, `Widgets-Mac` has `PrivacyInfo.xcprivacy` with:
  - `NSPrivacyTracking` false; `NSPrivacyTrackingDomains` empty; `NSPrivacyCollectedDataTypes` empty.
  - `NSPrivacyAccessedAPITypes`: `NSPrivacyAccessedAPICategoryUserDefaults` with `CA92.1`, plus `1C8F.1` in a target that uses App Group defaults. File timestamp `C617.1` or boot time `35F9.1` only if the code uses them (HIS-001 and the hub may; the Xcode privacy report decides).
  - Before every archive: Product ▸ Archive ▸ Generate Privacy Report; it matches this list.
- **R6** **Info.plist (iOS app; widget only if it fetches, NET-004 R15).**
  - `NSLocalNetworkUsageDescription`: "Levels connects to the Levels app on your Mac over your home Wi-Fi to show your Mac's and accessories' battery."
  - `NSBonjourServices`: `_levels._tcp`.
  - No other usage strings: Levels asks for no location, Bluetooth, contacts or tracking.
- **R7** **App Privacy answers** in App Store Connect:
  - "Do you or your third-party partners collect data from this app?" → **No** ("Data Not Collected").
  - Why: battery data goes only between the owner's own devices on the local network, or into the owner's iCloud private database, which the developer can't read (ADR-0019 Assumption). Purchases are handled by Apple; the app sends nothing to the developer (ADR-0021). No analytics, no crash SDK.
  - **Assumption:** local-network traffic between a person's own devices is not "collection" (it never reaches the developer). The owner confirms before submitting.
- **R8** **Legal pages.** Publish `docs/legal/privacy-policy.md` and `docs/legal/terms-of-use.md` (after owner review) at public HTTPS URLs. Put the privacy URL in the app record and the paywall; put the Terms URL in the paywall and in the App Store description (last line: "Terms of Use: <URL>"), or use Apple's standard EULA and link to it. Both URLs work without sign-in.

### Compliance and rating

- **R9** **Export compliance.** Levels uses only encryption that ships in Apple's operating systems: TLS in Network.framework (the hub's TLS-PSK, which also encrypts the payloads) and CryptoKit (X25519 and HKDF for pairing), plus CloudKit after launch, used only to protect the owner's own data. Answer: uses encryption → yes; qualifies for the exemption → yes. Set `ITSAppUsesNonExemptEncryption = NO` in the iOS Info.plist so each build skips the question. **Assumption:** this is the exempt case (OS-provided encryption, no proprietary algorithms); the owner confirms. No French declaration is needed under the exemption.
- **R10** **Age rating.** Answer "None" to every content question; no web browsing, no user-generated content, no chat, no ads, no contests. Expected result: the lowest rating (4+).

### Screenshots and review

- **R11** **Screenshots** (iPhone 6.9-inch set required; Apple scales it for smaller iPhones; iPad 13-inch set once iPad ships). Light mode, realistic device names that name no one ("MacBook Pro", "AirPods Pro", "iPhone"):
  1. Device list with a Mac, AirPods (left, right, case) and the iPhone.
  2. Home Screen with small, medium and large widgets.
  3. Lock Screen with circular and rectangular widgets.
  4. StandBy with the small widget.
  5. History chart (once iPhone history exists; otherwise skip).
  6. Low-battery alert notification (once iPhone alerts exist; otherwise skip).
  7. The paywall (optional; not needed for review, which uses the product review screenshot).
  Optional App Preview video: none for 1.0.
- **R12** **Review notes.** App Review has no Mac running Levels. The notes say:
  - "Levels shows the battery of the user's Apple devices. The iPhone app gets the Mac's and accessories' levels from the free Levels Mac app on the same Wi-Fi (download: <URL>), or from iCloud when both are signed in to the same Apple Account."
  - "Without a Mac, the app shows this iPhone's battery, the small widget, and the Levels Pro paywall. Tap a locked row or Settings ▸ Levels Pro to see it."
  - "To see the app with a Mac and accessories, tap Try with sample devices on the first screen" (demo mode, [DEMO-001](DEMO-001-sample-devices-mode.md)).
  - "Local Network access is used only to reach the user's own Mac."
  - A link to a short screen recording of pairing and Pro features (unlisted video).
  - No sign-in is needed, so no demo account.
- **R13** **Pre-submission checks.** MON-002 R13 checklist ticked; paywall shows price, period, trial terms, auto-renew text, Terms and Privacy links (guideline 3.1.2); Restore Purchases works (3.1.1); no text or link points to buying outside the App Store, and the Mac download link appears only in the review notes, the support page and as a "Get the Mac app" link that never mentions price or Pro (3.1.1, 3.1.3 do not apply because the Mac app is free).

### TestFlight

- **R14** **Versions and builds.** `MARKETING_VERSION` is shared by the iOS and Mac apps and starts at **1.0.0** at launch (the v0.x milestones are internal). `CURRENT_PROJECT_VERSION` is one integer for both apps that only goes up (1, 2, 3 …); it is set in `Config/Levels.xcconfig` and bumped once per uploaded or notarized build. A Mac-only fix still bumps the shared build number. Widgets use the same values as their host app.
- **R15** **TestFlight.** Archive Release for "Any iOS Device", upload from Xcode Organizer. Internal testing first (the owner, up to 100 team testers, no review). Test with a Sandbox Apple Account (App Store Connect ▸ Users and Access ▸ Sandbox): buy each product, trial, cancel, restore, refund via the sandbox account. **Assumption:** TestFlight subscriptions renew faster than real time; record the observed rate. External testers need beta review and a "What to test" note. The weekly reinstall ends here (owner decision N).

### Mac download (ADR-0022)

- **R16** **Signing.** Release, Developer ID Application certificate, Hardened Runtime on, App Sandbox off in the app (lead's call 16), on in the widget, Developer ID provisioning profile with iCloud, push and the App Group, `CloudKit.framework` linked (ADR-0013). Check: `codesign -dv --verbose=4`, `codesign -d --entitlements -`, `otool -L` shows CloudKit.
- **R17** **Notarize.** Store credentials once with `xcrun notarytool store-credentials`; submit with `xcrun notarytool submit Levels.dmg --keychain-profile <profile> --wait`; staple with `xcrun stapler staple` (app and dmg); check with `spctl -a -vv -t install Levels.dmg`. A script in `scripts/` does all of it (ADR-0013 follow-up).
- **R18** **Download page.** A public HTTPS page with the `.dmg`, the version, the minimum macOS (26), a SHA-256 of the file, the privacy and terms links, and "Requires macOS 26". The Mac app shows its version in About.

## Design

- Files touched at launch (not now, except R1): `Config/Levels.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, Team ID), the four `PrivacyInfo.xcprivacy`, `Levels-iOS/Info.plist` (R6, R9), entitlements per SETUP.md, `scripts/notarize.sh` (new).
- The In-App Purchase capability is added to `Levels-iOS` at enrollment (it needs the paid team).
- **Builder's call:** `.dmg` layout (app plus an Applications link); notarization script name and flags.

## Edge cases and failure modes

- The app name is taken: choose at R3; the bundle ID doesn't change.
- Upload rejected for a missing required-reason declaration: fix the manifest from the privacy report (R5).
- Products stuck in "Missing Metadata": usually the review screenshot or the agreement (R2, R4).
- App Review asks for a working demo of Pro without a Mac: demo mode ([DEMO-001](DEMO-001-sample-devices-mode.md), lead's call 36) and the recording (R12).
- Notarization fails: `xcrun notarytool log <id>` shows why; most often an unsigned nested binary or the Hardened Runtime missing.
- The Developer ID profile is missing: the Mac app won't launch on other Macs (ADR-0013 facts).

## Acceptance criteria

- [ ] AC1 — R1 items are in the repo before enrollment.
- [ ] AC2 — App Store Connect shows the app record, the group "Levels Pro" with two subscriptions and the trial, the lifetime product, Family Sharing on, grace period on, and all agreements active (R2–R4).
- [ ] AC3 — The Xcode privacy report of the archive matches R5 for both iOS targets.
- [ ] AC4 — App Privacy shows "Data Not Collected" (R7).
- [ ] AC5 — The privacy and terms URLs open without sign-in and match `docs/legal/` (R8).
- [ ] AC6 — The uploaded build doesn't ask the export question (R9).
- [ ] AC7 — The age rating is the lowest (R10).
- [ ] AC8 — Screenshots R11 1–4 uploaded for 6.9-inch iPhone.
- [ ] AC9 — A TestFlight build passes the sandbox purchase, trial, restore and refund run (R15), recorded with dates.
- [ ] AC10 — On a second Mac that never ran Levels, the downloaded `.dmg` opens without a Gatekeeper warning, the app launches, reads the battery and AirPods, and syncs with iCloud (R16–R18).
- [ ] AC11 — Build numbers of the iOS upload and the Mac download come from one counter and only go up (R14).
- [ ] AC12 — MON-002 R13 and R13 here ticked before "Submit for Review".

## Tests

All manual. AC3 and AC6 are checked on each archive. AC10 needs a second Mac (or a fresh user account on the same Mac, which is weaker: note which).

## Open questions

1. **Mac updates.** The Mac download has no update channel. Options: (a) a "Check for updates" link to the download page; (b) Sparkle, which is third-party code and breaks ADR-0019 rule 2; (c) a tiny own check that reads a version file from the download page. Lead's recommendation: (c), no third-party code.
2. **Hosting.** Where do the privacy policy, terms, support page and Mac download live (for example GitHub Pages for this repo)? Needs a public HTTPS URL.
3. **Contact.** Which email goes on the support page and legal pages (`<contact email>` placeholder for now)?
4. **Seller name.** An individual account shows the owner's legal name on the App Store. Fine, or enroll as an organization (needs a D-U-N-S number)?
5. **Export compliance.** Confirm the exempt answer (R9).
6. **Apple Watch.** When the Watch app ships later, is it Pro?
