# ADR-0022: iPhone and iPad in the App Store, the Mac as a notarized download

- **Status:** Proposed
- **Date:** 2026-11-24
- **Deciders:** project owner
- **Related:** ADR-0002, ADR-0003, ADR-0004, ADR-0005, ADR-0013, ADR-0015, ADR-0019, ADR-0020, ADR-0021, REL-001, SYNC-001, MAC-001

## Context

Owner decision Q (2026-11-24): the iPhone app (and later the iPad app) ships in the App Store. The Mac app ships as a notarized direct download (Developer ID) and stays unsandboxed, so it keeps reading AirPods levels through `system_profiler` (ADR-0015). Owner decision N: enroll in the paid Apple Developer Program only at launch.

ADR-0013 already chose Developer ID for the Mac, for the owner's own Macs. This ADR extends it to public distribution and lists what needs the paid account.

Today (free Personal Team, SETUP.md):

- No iCloud, no push, no TestFlight, no App Store Connect, no Developer ID certificate, no notarization.
- iPhone installs expire after 7 days (`scripts/reinstall.sh`).
- The Mac build is development-signed and runs only on the owner's Mac.

### Facts (from Apple documentation)

- The Developer ID certificate, notarization, App Store Connect, TestFlight, CloudKit and push all need the paid Apple Developer Program. ([Membership details](https://developer.apple.com/programs/whats-included/))
- A Developer ID app can use CloudKit, push and App Groups when it embeds a Developer ID provisioning profile (ADR-0013 facts).
- Notarization needs the Hardened Runtime and a Developer ID signature. `notarytool` submits; `stapler` attaches the ticket so Gatekeeper can check it offline. ([Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution))
- A Mac app distributed outside the Mac App Store can't offer App Store in-app purchases (ADR-0021).

## Decision

1. **iPhone and iPad:** one iOS app in the App Store (universal purchase is automatic for one iOS app with iPad support). Levels Pro is sold there (ADR-0021). iPad joins when UI-005 is built; Watch later, inside the iOS app.
2. **Mac:** a free Developer ID app, Hardened Runtime, **App Sandbox off**, a Developer ID provisioning profile for iCloud, push and the App Group, notarized and stapled, shipped as a `.dmg` (the `.dmg` is notarized too). The widget extension stays sandboxed (lead's call 16). This confirms ADR-0013 for public release; ADR-0013 stays Accepted.
3. **No Mac App Store build for now.** The sandbox blanks AirPods levels. The code stays sandbox-compatible behind `LEVELS_UNSANDBOXED` (ADR-0013), so the door stays open.
4. **Same identifiers on both.** The iOS app and the Mac app share the bundle ID root and the iCloud container `iCloud.<rdns>.levels` (ADR-0003, ADR-0005), so one CloudKit private database serves both. The bundle ID root is filled in at enrollment (owner decision B).
5. **What waits for the paid account** (owner decision N), done at launch in this order (REL-001 has the checklist):
   1. Enroll; get the paid Team ID; update `DEVELOPMENT_TEAM` and the App Group and keychain group IDs (SETUP.md).
   2. Put the iCloud and push entitlements back (SETUP.md block); SPIKE-001; SYNC-001 replaces the hub (lead's call 27).
   3. App Store Connect: app record, Paid Applications Agreement, tax and banking, the three Pro products.
   4. Developer ID Application certificate, Developer ID provisioning profile, notarization.
   5. TestFlight for the iPhone app; the weekly reinstall ends.
6. **What works now on the free team:** all of MON-001 and MON-002 against a local `.storekit` file, the privacy manifest, Info.plist keys, legal drafts and screenshots.
7. **Versions.** One marketing version for both apps (`MARKETING_VERSION`, starting 1.0.0 at launch). Build numbers (`CURRENT_PROJECT_VERSION`) are one integer that only goes up, shared by both apps (REL-001 R14).

## Options considered

### Option A — iOS in the App Store, Mac by Developer ID download (chosen)
- Pros: the Mac keeps AirPods left, right and case; no Mac App Review; the iPhone gets App Store payments, TestFlight and automatic updates.
- Cons: two release paths; the Mac has no automatic updates without extra work; the Mac can't sell Pro.

### Option B — Both in the App Store
- Pros: one store, automatic updates, Pro sold on the Mac too.
- Cons: the Mac must be sandboxed and loses AirPods per-bud and case levels (ADR-0013, ADR-0015). Rejected.

### Option C — Stay on the free team, no store
- Pros: no cost.
- Cons: no iCloud, 7-day installs, no one else can install it. Doesn't meet owner decision Q.

## Consequences

- Positive: each platform ships the way that keeps its best feature; iCloud and TestFlight come with the same $99.
- Negative / accepted risks:
  - The Mac app has no update channel. Users must download new versions by hand until one is chosen (open question in REL-001).
  - App Review tests the iPhone app without the owner's Mac. The review notes must explain the Mac download and how to see Pro features (REL-001 R12).
  - An individual developer account shows the owner's legal name as the seller on the App Store.
- Follow-ups: a notarization script (ADR-0013 follow-up); a download page for the Mac app; decide the Mac update channel.

## References

- [Developer ID](https://developer.apple.com/support/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple Developer Program: what's included](https://developer.apple.com/programs/whats-included/)
- [Offering universal purchase](https://developer.apple.com/support/universal-purchase/)
