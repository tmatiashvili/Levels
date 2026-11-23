# ADR-0007: Device identity is a random UUID in a non-syncing, this-device-only Keychain item

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0005, ADR-0013, SYNC-001, SYNC-002

## Context

Each device writes one record whose name is its `deviceId` (ADR-0005). The ID must:
- stay the same across launches, app updates and (ideally) reinstalls;
- be the same in the app, its widget extensions and App Intents on that device;
- **never** be shared by two physical devices. If iCloud Keychain synced it, every device would overwrite the same record.

Verified facts:
- Items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` "do not migrate to a new device. Thus, after restoring from a backup of a different device, these items will not be present." ([doc](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly))
- "This device only" items are protected with the device UID key when backed up, which makes them "useless if restored to a different device". ([Apple Platform Security – Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web))
- On macOS, `kSecUseDataProtectionKeychain = true` makes an item behave like an iOS item, so access groups and accessibility apply. Setting `kSecAttrSynchronizable` to true would add iCloud sync. ([kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain))
- Keychain sharing between an app and its extensions uses the `keychain-access-groups` entitlement. ([Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps))
- `identifierForVendor` exists on iOS and watchOS but not macOS. It resets when all of the vendor's apps are removed. ([UIDevice.identifierForVendor](https://developer.apple.com/documentation/uikit/uidevice/identifierforvendor))

## Decision

Store `deviceId` as a generic-password Keychain item:

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `<bundle-prefix>.levels.device-identity` |
| `kSecAttrAccount` | `deviceId` |
| `kSecAttrAccessGroup` | `$(AppIdentifierPrefix)<bundle-prefix>.levels.shared` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `kSecAttrSynchronizable` | `false` (set explicitly, on add **and** query) |
| `kSecUseDataProtectionKeychain` | `true` (required on macOS, ignored elsewhere) |
| value | 16 random bytes (`UUID()`), stored as its string |

Rules:
1. **Read first.** Create a new UUID only on `errSecItemNotFound`. On any other error, especially `errSecInteractionNotAllowed` (a background launch before first unlock), do **not** create an ID. Skip reporting for this wake and try later. Creating an ID here would make a ghost duplicate.
2. Create with `SecItemAdd`. If it returns `errSecDuplicateItem` (another process won the race), read again and use the stored value.
3. The app, widget extensions and App Intents share the access group above. Widgets need the ID only to mark "this device".
4. **Restore or migration to a different device:** the item is absent, so the device gets a **new ID** and a new record. The old device's record stays, frozen, and moves to "Old devices" after 30 days. The owner can remove it (ADR-0005). This is the correct outcome when the old device is still in use (for example the owner keeps the old iPad), and a harmless extra record when it isn't.
5. **Restore to the same device** (erase and restore): the item should come back, so the ID and record are kept. **Assumption:** UID-wrapped `ThisDeviceOnly` items restore to the same hardware from an encrypted or iCloud backup. If they don't, rule 4 applies.
6. **App deletion and reinstall:** **Assumption:** iOS keeps Keychain items after the app is deleted, so the ID survives. If not, rule 4 applies.
7. Never read or write this item with `kSecAttrSynchronizableAny`.
8. **Display name** (not part of identity, but set alongside it; detail in SYNC-002 R17): since iOS 16 `UIDevice.name` returns a generic name without the user-assigned-device-name entitlement, so the default name is the model name ("iPhone", "iPad", "Apple Watch"). The Mac uses its computer name if available (**Assumption:** `Host.current().localizedName` returns it inside the sandbox; verify), else "Mac". The user can rename **this** device in the app; the new name is written to the device's own record, so every device shows it. Hiding a device stays local to each device in v0.1.

## Options considered

### Option A — Keychain, ThisDeviceOnly, not synchronizable (chosen)
- Pros: Never shared between devices, even via backup restore to new hardware. Shared with extensions. Works on all four platforms. Survives app updates.
- Cons: Restore to a new device creates a ghost record that needs manual removal. Unreadable before first unlock after reboot. Needs the keychain-sharing entitlement.

### Option B — Synchronizable Keychain item (iCloud Keychain)
- Pros: Survives every migration.
- Cons: **Fatal:** all devices on the Apple ID would get the same ID and overwrite one record.

### Option C — Keychain with plain `AfterFirstUnlock` (migrates in encrypted backups)
- Pros: Restore to a new phone keeps the old record. No ghost.
- Cons: Restoring the old iPad's backup to a new iPad while keeping the old one gives two live devices with one ID. They overwrite each other silently. That is a worse failure than a ghost.

### Option D — `identifierForVendor`
- Pros: No Keychain code.
- Cons: Not on macOS. Resets when all of the vendor's apps are deleted. Not readable from every extension in the same way.

### Option E — UUID in an App Group file or UserDefaults
- Pros: Simple. Visible to extensions.
- Cons: Included in device backups, so a restore to new hardware duplicates the ID (same failure as Option C). Lost when the group container is removed.

## Consequences

- Positive: The worst case is a visible, removable ghost record, never two devices fighting over one record.
- Negative / accepted risks: Ghost records after device upgrades. Reporting is skipped on wakes before first unlock.
- Follow-ups: On macOS the data protection keychain and the access-group entitlement need a provisioning profile, which links to ADR-0013. **Assumption:** a Developer ID build with a profile can use the data protection keychain with an access group, just like an App Store build. Optional later polish (UI): on first run with a new ID, offer "Replace <old device>?" when an older record has the same `type` and `name`.

## References

- [kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable)
- [kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Apple Platform Security: Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web)
- [UIDevice.identifierForVendor](https://developer.apple.com/documentation/uikit/uidevice/identifierforvendor)
