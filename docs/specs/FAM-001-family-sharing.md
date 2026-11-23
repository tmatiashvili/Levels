---
id: FAM-001
title: Family sharing
milestone: later
status: Outline
depends_on: [SYNC-001, SYNC-002]
adrs: [4, 5, 6, 7, 19]
targets: [Shared, Levels-iOS, Levels-Mac, Levels-Watch, Widgets-iOS, Widgets-Mac, Widgets-Watch]
---

# FAM-001: Family sharing

## Why

A parent may want to see whether a child's iPad or a partner's iPhone is about to die. Each person has their own Apple ID, so today's design (one private database) can't show their devices. CloudKit sharing lets one person invite others to read their device records.

## Scope

- In: an owner shares their devices read-only with invited people (each with their own Apple ID); invited people see a "Shared with me" section; either side can stop sharing; per-device choice of what is shared.
- Out: writing to someone else's devices; alerts for family devices in the first version (see Design); history sharing until HIS-001 exists (then opt-in); Family Sharing groups from Apple's Family Sharing settings (CloudKit has no "share with my Family Sharing group" switch — **Assumption**, invitations are per person).

## Behaviour

- R1 — The owner picks people to invite and which of their devices to share. Default: none of their devices pre-selected.
- R2 — Invited people get a link (Messages, Mail, etc.), accept it, and see the owner's shared devices with the owner's name as a section header.
- R3 — Shared access is read-only.
- R4 — The owner can remove a person or stop sharing at any time; the person's view empties on next sync. A participant can leave on their own.
- R5 — "Remove all my data" (ADR-0019) also ends all shares.

## Design

### Facts (verified)

- A `CKShare` shares either a whole record zone or a record hierarchy (via each record's `parent`). Shareable records must live in a custom zone in the private database. A record can be in only one share. Up to 100 participants, each with an active iCloud account. The app needs `CKSharingSupported` = true in Info.plist. A zone-wide share has record name `CKRecordNameZoneWideShare`. ([CKShare](https://developer.apple.com/documentation/cloudkit/ckshare))
- Participants with write permission can modify or delete shared records; read-only participants can't. (same page)
- "Only public and private databases support query subscriptions." Saving one in the shared database returns an error. ([CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription))
- "Only private and shared databases support database subscriptions." A `CKDatabaseSubscription` fires for changes in any custom zone in that database, which matters for the shared database "because you don't know what record zones exist in advance". Changes are fetched with `CKFetchDatabaseChangesOperation` then `CKFetchRecordZoneChangesOperation`, using server change tokens. The default zone of the private database doesn't take part. ([CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription))

### Options

**Option A — Share the whole device zone (zone-wide `CKShare`)**
- Pros: simplest; one share; every current and future device included automatically.
- Cons: all-or-nothing; can't keep a work Mac private; history (HIS-001) goes along if it lives in the same zone.

**Option B — Hierarchy share: a `Household` root record, shared devices set `parent` to it (recommended)**
- Pros: per-device choice (R1); history records can stay out by not setting `parent`.
- Cons: changing `parent` is a write on each device record; device records are written by their own devices, so the parent link must survive their regular saves (ADR-0005/0008 must keep the field).

**Option C — A separate "shared" zone with copies of shared devices**
- Pros: clean separation; private zone never shared.
- Cons: two writes per report; copies can drift; more sync code.

**Recommendation:** Option B, read-only participants.

### Sync for participants

- Participants receive changes through a `CKDatabaseSubscription` in the **shared** database (query subscriptions aren't allowed there), then fetch database and zone changes with change tokens. ADR-0006 already uses a `CKDatabaseSubscription` on the private database, so both sides use the same subscription type; the shared side adds change-token fetches (`CKFetchDatabaseChangesOperation`), which ADR-0004's token-free full-zone fetch does not need today.
- Shared data goes into the same App Group cache (ADR-0009), tagged with owner, so widgets can show it (as an opt-in section).
- Alerts: ALR-001 Option C relies on a query subscription with a visible alert, which isn't allowed in the shared database. Family alerts would need the silent database-subscription path (best effort) or a visible `NotificationInfo` on the database subscription (**Assumption:** possible, but it can't filter by record content, so it would alert on every change). So: no family alerts in the first version.
- UI: `UICloudSharingController` on iOS/iPadOS; **Assumption:** SwiftUI `ShareLink` with a `CKShare` transfer representation works on iOS and macOS 26 and is simpler; to verify.

### Privacy implications (with ADR-0019)

- Shared data is personal: device names often contain the owner's name, and update times show routines (sleep, work hours, travel). The share screen says this plainly before sending.
- Read-only by default; no participant can change or delete the owner's records.
- History is not shared unless the owner turns it on separately.
- Leaving or removing someone stops new data; data already seen on their devices is not erased from their cache until their next sync. **Assumption:** CloudKit removes the zone from the participant's shared database promptly after removal.
- App Store label: still "Data Not Collected" (**Assumption**, ADR-0019): sharing happens between users via Apple, not with the developer.

## Edge cases and failure modes

- Invitee has no iCloud account: can't accept (per CKShare facts); show why.
- Owner's device record recreated with a new ID (ADR-0007): loses `parent`, so it stops being shared; owner must re-pick it.
- Owner deletes the zone ("Remove all my data"): share ends for everyone.
- Many owners shared with one person: shared database contains several zones; the database subscription covers all.
- Same person on both sides (share with yourself): block in UI.

## Acceptance criteria

- [ ] AC1 — Given the owner shares their iPad with a second Apple ID, when that person accepts, then they see the iPad with live levels and can't edit it.
- [ ] AC2 — Given the owner un-shares the iPad, when the participant's app next syncs, then the iPad disappears.
- [ ] AC3 — Given a share exists, when the participant's app saves a query subscription in the shared database, then it is not used; a database subscription is (integration check in a separate test container, ADR-0018 §6).
- [ ] AC4 — Given the owner's non-shared Mac, then it never appears for the participant.

## Tests

Merge of private and shared cache data and the "owner" tagging are Swift Testing unit tests with a fake `CloudDatabase` (ADR-0018) that models both databases. AC1–AC4 need two real Apple IDs on real devices (manual QA spec for the milestone).

## Open questions

- Closed. Lead's call (2026-11-23): family sharing is parked until an App Store decision is made.
- If built, should participants also share back automatically (two-way family view)? Recommended: no; each person shares explicitly.
