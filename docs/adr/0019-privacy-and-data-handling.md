# ADR-0019: Keep all data in the user's private CloudKit database, collect nothing, and offer one "Remove all my data" action

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0005, ADR-0007, ADR-0009, ADR-0018, FAM-001, HIS-001

## Context

Levels stores a little data about each device: a name, a type, battery level, charging and low-power state, and a timestamp (ADR-0005). It is not sensitive like health data, but some of it is personal:

- Device names often include a person's name ("Tornike's iPhone").
- Timestamps and charging patterns show when someone is awake, travelling or at a desk. History (HIS-001) makes this richer.
- Accessory names (v0.3) can include names too ("Tornike's AirPods").

The owner decided: no backend, no analytics, data stays in the user's private iCloud database.

Facts (verified):

- On iOS 16 and later, `UIDevice.name` returns a generic name ("iPhone"). The user-assigned name needs the entitlement `com.apple.developer.device-information.user-assigned-device-name`, which Apple grants only if the name is shown in the UI, powers a multi-device feature, isn't used for tracking, and isn't shared with third parties other than cloud hosting "for the purposes of storage or syncing only". Levels fits these criteria. ([UIDevice.name](https://developer.apple.com/documentation/uikit/uidevice/name), [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.device-information.user-assigned-device-name)) Levels does not request it: the default name is the model name and the user can rename this device in the app (ADR-0007 rule 8, SYNC-002 R17).
- A privacy manifest `PrivacyInfo.xcprivacy` records collected data types (all platforms) and required-reason API use (iOS, iPadOS, tvOS, visionOS, watchOS; **not macOS**). Each bundle whose executable uses a required-reason API needs its own manifest, so app extensions need one too. Since 1 May 2024 App Store Connect rejects uploads that use these APIs without declared reasons. ([Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api))
- Required-reason categories and the reasons that fit Levels ([NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)):

  | Category | Triggering APIs | Do we use it? | Reason |
  |---|---|---|---|
  | `NSPrivacyAccessedAPICategoryUserDefaults` | `UserDefaults` | Yes. Apple's own CloudKit guidance stores "subscription saved" state in `UserDefaults`. | `CA92.1` (app-only data). Add `1C8F.1` if a target reads or writes App Group defaults (`UserDefaults(suiteName:)`, ADR-0009). |
  | `NSPrivacyAccessedAPICategoryFileTimestamp` | `creationDate`, `modificationDate`, `contentModificationDateKey`, `stat` and friends | Only if code checks the cache file's modification date. | `C617.1` (files in the app container, App Group container or CloudKit container). Preferred: don't use it; store `updatedAt` inside the cached data. |
  | `NSPrivacyAccessedAPICategorySystemBootTime` | `ProcessInfo.systemUptime`, `mach_absolute_time()` | Only if the throttle or staleness logic uses uptime. | `35F9.1` (measure time between in-app events). |
  | `NSPrivacyAccessedAPICategoryDiskSpace` | volume capacity keys, `statfs` | No. | — |
  | `NSPrivacyAccessedAPICategoryActiveKeyboards` | `activeInputModes` | No. | — |

- App Store privacy labels: "collect" means "transmitting data off the device in a way that allows you and/or your third-party partners to access it" beyond servicing the request. For Apple services like CloudKit, "You are not responsible for disclosing data collected by Apple." ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/))
- Deleting a record zone "is a permanent action that deletes every record in that zone. You can't restore a deleted record zone." It fails without network or an iCloud account. ([modifyRecordZones(saving:deleting:)](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecordzones(saving:deleting:)))

Assumptions:

- **Assumption:** Swift's `ContinuousClock` / `SuspendingClock` and `Date()` are not in the required-reason list and need no declaration (the list names `systemUptime` and `mach_absolute_time()` only). Confirm with Xcode's privacy report on the first archive.
- **Assumption:** because the developer can't read a user's private CloudKit database, data stored only there counts as "not collected", so the label is "Data Not Collected". Apple's page doesn't say this about the private database in so many words.
- **Assumption:** all synced records live in one custom zone (ADR-0005). The default zone of the private database can't be deleted as a whole, so "Remove all my data" depends on this.

## Decision

1. **Where data lives.** Battery data lives only in (a) the user's CloudKit private database, (b) the App Group cache on each device (ADR-0009), and (c) the device ID in the Keychain (ADR-0007). Nothing goes to any other server.
   - Note (owner decision M, 2026-11-24): in the free-team hub build there is no CloudKit. Data travels only between the owner's paired devices on the local network, encrypted with TLS-PSK, and the pairing keys live in each device's Keychain (ADR-0020). No server is involved. The Bonjour name names no one. Pairing keys come from an X25519 key agreement confirmed by the owner comparing a 6-digit number on both screens (lead's call 30), so a guessed or recorded pairing code doesn't expose them.
   - Note (owner decision U, 2026-11-24): after enrollment, push updates go through a small relay (ADR-0023). It sees push tokens and, for the "Follow charging" Live Activity, one level and charging state without names. It logs nothing, stores no raw token, and keeps only rate-limit counters keyed by hashes for up to 25 hours. The privacy policy must mention it.
2. **No third-party code.** No third-party SDKs, analytics, crash reporters or ad libraries. Swift packages from Apple only. Crash data comes from Apple's opt-in diagnostics (Xcode Organizer) only.
3. **Collect the minimum.** Store only the fields in ADR-0005. No location, no Wi-Fi/network names, no serial numbers, no hardware identifiers. Device names are shown to the user and synced; they are never logged with `privacy: .public` in `os_log`/`Logger` (log names as private).
4. **Privacy manifest in every target** (`Levels-iOS`, `Levels-Watch`, `Widgets-iOS`, `Widgets-Watch`, and `Levels-Mac`/`Widgets-Mac` for consistency even though macOS doesn't require reasons):
   - `NSPrivacyTracking` = false; `NSPrivacyTrackingDomains` empty; `NSPrivacyCollectedDataTypes` empty.
   - `NSPrivacyAccessedAPITypes`: UserDefaults with `CA92.1` (plus `1C8F.1` in any target that uses App Group defaults). Add file-timestamp `C617.1` or boot-time `35F9.1` only if code uses those APIs.
   - Before each archive, generate Xcode's privacy report and check it matches this list.
5. **If published:** App Store privacy label "Data Not Collected" (**Assumption** above); a short privacy policy page saying: data stays in your iCloud, the developer can't see it, how to delete it. A privacy policy URL is required for App Store apps.
6. **"Remove all my data".** A settings action on iPhone/iPad/Mac, behind a confirmation that explains the effect:
   1. Delete the custom zone in the private database (this removes every device's records and history).
   2. Delete this device's subscriptions (ADR-0006).
   3. Clear the App Group cache and reload widgets.
   4. Keep the Keychain device ID (it identifies the device, not the person), but stop reporting until the user turns reporting back on. Turning it back on re-creates the zone and subscription and writes only this device's own record.
   - Lead's call (2026-11-23): ships in v0.1 (UI-002 R12, UI-004 R9).
   - Other devices still running Levels will recreate their own records on their next report. The confirmation says so: "Turn off Levels on your other devices first, or they will add themselves back."
   - Offline or signed out: show an error and do nothing. Never half-delete.
   - The user can also delete the data in iOS Settings > [name] > iCloud > Manage Storage (**Assumption:** Levels appears there once it stores data).
7. **"Remove this device"** (a single record, for a sold or lost device) belongs to the sync and UI specs. Lead's call (2026-11-23): it ships in v0.1 as Remove in the "Old devices" section (UI-002 R11, SYNC-001 R15).

## Options considered

### Option A — Private DB only, no SDKs, zone delete (chosen)
- Pros: nothing to disclose; no server to secure; Apple handles encryption at rest and account security; one simple delete.
- Cons: no crash or usage data beyond Apple's opt-in diagnostics; the owner learns about bugs only by using the app.

### Option B — Add a privacy-friendly analytics or crash SDK (for example TelemetryDeck, Sentry)
- Pros: real crash reports and usage numbers if published.
- Cons: breaks the owner's "no analytics" rule; needs a privacy label entry and SDK manifest review; a third party receives data. Rejected.

### Option C — Store history and names only locally, sync only current level
- Pros: less personal data in iCloud.
- Cons: other devices couldn't show names or history, which is the whole point. HIS-001 weighs storage per sample instead.

### Option D — Delete records one by one instead of the zone
- Pros: works even if records sit in the default zone.
- Cons: many requests; partial failures leave leftovers; slower. Use only as a fallback if ADR-0005 keeps the default zone.

## Consequences

- Positive: App Store review should be simple; the label is the smallest possible; the owner's data never leaves Apple's systems.
- Negative / accepted risks: no remote crash data; "Remove all my data" can be undone by another device's next report; family sharing (FAM-001) would send device names to other people and needs its own consent step.
- Follow-ups: request the user-assigned device name entitlement only if the owner later wants automatic names (approval takes time); add `PrivacyInfo.xcprivacy` to each target in the project skeleton (ADR-0003); write the privacy policy page before any App Store submission.

## References

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [NSPrivacyAccessedAPIType reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/)
- [UIDevice.name](https://developer.apple.com/documentation/uikit/uidevice/name) and [user-assigned device name entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.device-information.user-assigned-device-name)
- [CKDatabase.modifyRecordZones(saving:deleting:)](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecordzones(saving:deleting:))
