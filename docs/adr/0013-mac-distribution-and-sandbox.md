# ADR-0013: Ship the Mac app with Developer ID and notarization, sandboxed until v0.3

- **Status:** Accepted
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004..0009 (sync), ADR-0010 (BatteryReader), ADR-0014, ADR-0015, MAC-001, MAC-002, MAC-003, SYNC-001

## Context

The Mac app is a menu-bar agent (ADR-0014). It must read the Mac's own battery (v0.1), later read accessory batteries (v0.3, ADR-0015), and use CloudKit and silent push (ADR-0004..0009). Levels is a personal tool first; the App Store may come later. Two ways exist to ship a Mac app to the owner's own Macs:

1. **Mac App Store / TestFlight.** App Sandbox is mandatory. App Review applies and private API use is rejected.
2. **Developer ID + notarization** (download or copy the `.app`). App Sandbox is optional. Hardened Runtime and notarization are required for Gatekeeper to open it without warnings.

Both need the paid Apple Developer Program ($99/year). The README already requires it for CloudKit, push and App Groups, so neither option adds cost.

### Facts verified

- **Developer ID supports CloudKit and push.** Apple: "Applications can also take advantage of advanced capabilities such as CloudKit and push notifications." These need a **Developer ID provisioning profile** embedded in the app. Gatekeeper checks the profile at install and at every launch, and "if your Developer ID provisioning profile expires, the app will no longer launch". Profiles made after 22 Feb 2017 are valid for 18 years. ([Developer ID](https://developer.apple.com/support/developer-id/))
- **Sandbox probe on this Mac.** I built a small Swift probe and ran it three ways: unsandboxed, ad-hoc signed inside an `.app` with `com.apple.security.app-sandbox`, and with the sandbox plus `com.apple.security.device.bluetooth`. The Mac was a MacBook on battery running macOS 27.2.1. That is newer than our minimum of 26, so results on 26 are an **Assumption:** expected to match. The probe was ad-hoc signed and launched from Terminal, not a notarized app launched by Launch Services.

| Check | Unsandboxed | Sandboxed | Sandboxed + bluetooth entitlement |
|---|---|---|---|
| `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription` (current 69, max 100, `InternalBattery`) | works | works | works |
| `ProcessInfo.isLowPowerModeEnabled` | works | works | works |
| `IOServiceGetMatchingServices` + `IORegistryEntryCreateCFProperty` on `AppleDeviceManagementHIDEventService` and `AppleSmartBattery` | works | works | works |
| Spawn `/usr/sbin/ioreg -r -k CurrentCapacity -l` | full output | **full output** (the child inherits the sandbox, but registry reads are allowed) | full output |
| Spawn `/usr/sbin/system_profiler SPBluetoothDataType -json` | full output, including AirPods case/left/right | **empty**: `{"SPBluetoothDataType":[{}]}`, stderr `controllerInfo == nil` | **empty** |
| Read `/Library/Preferences/com.apple.Bluetooth.plist` | readable | **denied** (Cocoa error 257) | readable |
| `IOBluetoothDevice.pairedDevices()` | 0 devices | 0 | 0 |

  Notes on the probe:
  - The Bluetooth plist on this Mac is only 321 bytes and has no battery keys. The old `BatteryPercent*` keys that apps such as AirpodsBattery-Monitor still parse are gone, so that file is no longer a battery source.
  - `IOBluetoothDevice.pairedDevices()` returned 0 even unsandboxed. **Assumption:** this is because the Bluetooth privacy (TCC) permission was missing for a process started from Terminal; a real app with `NSBluetoothAlwaysUsageDescription` would prompt and see devices. Not verified.
- **CloudKit in a sandboxed app on macOS 26.** DTS confirmed that the sandbox grants the `com.apple.cloudd` mach-lookup exception only when `CloudKit.framework` is linked into the binary. Without it you get `CKError 6`, "Error connecting to CloudKit daemon". It hit TestFlight and App Store builds and also development-signed builds launched outside Xcode. The fix is to link `CloudKit.framework` explicitly in the app target and check with `otool -L`. ([forum 835400](https://developer.apple.com/forums/thread/835400), [forum 842234](https://developer.apple.com/forums/thread/842234))
- **What open-source accessory-battery apps do.** [AirBattery](https://github.com/lihaoyun6/AirBattery) runs its main app without the sandbox (empty entitlements file) and reads AirPods through `system_profiler SPBluetoothDataType -json` (`device_batteryLevelCase/Left/Right`). It reads Magic peripherals through the IOKit `BatteryPercent` property and private `IOBluetoothDevice` selectors. Only its widget is sandboxed. [AirpodsBattery-Monitor-For-Mac](https://github.com/mohamed-arradi/AirpodsBattery-Monitor-For-Mac) sets `app-sandbox = false` and parses `system_profiler` and the Bluetooth plist. Neither is on the Mac App Store.

## Decision

**Ship the Mac app as Developer ID, notarized, with Hardened Runtime and a Developer ID provisioning profile, for iCloud (CloudKit), push and the App Group.** Keep **App Sandbox on** for v0.1 and v0.2, because everything those versions need works in the sandbox. That keeps the Mac App Store path open at no cost. Owner decision (2026-11-23): the Mac ships Developer ID + notarized; sandbox on for v0.1–v0.2, off from v0.3. At v0.3 the AirPods reader needs `system_profiler`, which the sandbox blanks (ADR-0015), so then:

- the **Developer ID build turns App Sandbox off**, by a build setting in the Mac target only;
- the code stays sandbox-compatible. Every reader that needs the sandbox off sits behind ADR-0010's `BatteryReader` protocol and is compiled under a flag (`LEVELS_UNSANDBOXED`), so a future App Store build drops AirPods left/right/case and keeps everything else.

> **Note (lead's call 16, 2026-11-23):** MAC-003 accessories were pulled forward from v0.3 into the free-team, Mac-first build (owner decision K). That build is personal-only (free Personal Team, no distribution), so the Mac app's sandbox is now **off in Debug and Release**, not only in the Developer ID Release: `ENABLE_APP_SANDBOX = NO` and `SWIFT_ACTIVE_COMPILATION_CONDITIONS += LEVELS_UNSANDBOXED` in `Config/Levels-Mac.xcconfig`, and no `com.apple.security.app-sandbox` key in `Levels-Mac/Levels-Mac.entitlements`. Re-tested before the change: an ad-hoc signed probe app running `/usr/sbin/system_profiler SPBluetoothDataType -json` got 1,652 bytes unsandboxed and 48 bytes (`{"SPBluetoothDataType":[{}]}`, stderr `controllerInfo == nil`) sandboxed, with or without `com.apple.security.device.bluetooth`. Unsandboxed, the App Group container and the Keychain device ID keep working (same device ID before and after). The widget extension stays sandboxed. The code stays sandbox-compatible: a future App Store configuration drops the flag and keeps the IOKit HID reader.

Builder specifics:
- Signing for the owner's own Macs: Release build, Developer ID Application certificate, notarized with `notarytool`, stapled. Distribute the `.app` in a zip or `.dmg`. Sparkle or any other auto-update is out of scope while the tool is personal.
- Link `CloudKit.framework` explicitly in the Mac app target, whether sandboxed or not.
- Use the CloudKit **Production** environment for every Mac build, Debug included (ADR-0005 rule 5, owner decision 2026-11-23). The entitlements file sets `com.apple.developer.icloud-container-environment = Production` explicitly; it is not left to export. The builder checks the exported entitlements (MAC-001 AC11).
- The entitlement list lives in MAC-001.

## Options considered

### Option A — Developer ID + notarization, sandbox on until v0.3, then off (chosen)
- Pros: no App Review; installs on the owner's Macs today; CloudKit and push both work; nothing is lost for v0.1–v0.2 because the sandbox stays on; v0.3 can use the only source that exposes AirPods left/right/case.
- Cons: the owner has to notarize each build (scriptable). No automatic updates without extra work. The provisioning profile must stay valid (18 years). Turning the sandbox off at v0.3 widens what a bug could reach.

### Option B — Mac App Store only (sandbox required)
- Pros: automatic updates, TestFlight, one review path that iOS also uses.
- Cons: App Review for a personal tool; AirPods per-bud and case levels are impossible (sandboxed `system_profiler` is empty, private IOBluetooth selectors are rejected); the macOS 26 CloudKit-in-sandbox pitfall above.

### Option C — Both from day one
- Pros: maximum reach.
- Cons: two signing pipelines, two review surfaces and two behaviours for a single user. Premature.

### Option D — Developer ID, never sandboxed
- Pros: simplest; any API works from v0.1.
- Cons: sandbox-incompatible code would creep in unnoticed and close the App Store path. It gains nothing for v0.1–v0.2.

## Consequences

- Positive: the owner can install v0.1 without App Review. One codebase can still produce an App Store build later.
- Negative / accepted risks: at v0.3 the Developer ID build loses sandbox protection. The app holds no secrets beyond the iCloud session and has no network surface besides CloudKit, so we accept this. If the owner ever ships to the App Store, AirPods there show one level per headset at best (ADR-0015).
- Follow-ups: a notarization script (`scripts/` or Xcode archive post-action) is a builder task in MAC-001. Re-check this ADR if Apple adds a public AirPods battery API on macOS.

## References

- Developer ID: https://developer.apple.com/support/developer-id/
- Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Supported capabilities (macOS): https://developer.apple.com/help/account/reference/supported-capabilities-macos
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- Forum 835400, sandbox denies `com.apple.cloudd` on macOS 26: https://developer.apple.com/forums/thread/835400
- Forum 842234, the same issue outside Xcode: https://developer.apple.com/forums/thread/842234
- AirBattery (open source): https://github.com/lihaoyun6/AirBattery
- AirpodsBattery-Monitor-For-Mac (open source): https://github.com/mohamed-arradi/AirpodsBattery-Monitor-For-Mac
