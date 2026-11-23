# SPIKE-001 push check: how to run it

This folder holds throwaway code for [SPIKE-001](../docs/specs/SPIKE-001-debug-build-push-check.md).
It answers one question: does an iPhone **Debug** build from Xcode get the CloudKit silent push for the **Production** container?
Delete this folder after the result is written down.

- `PushCheck-iOS/` is the iPhone app. It saves the subscription and logs every push.
- `PushCheck-Mac/` is the Mac app. It has one button that writes one test record.

Plan about 60 minutes the first time: 30 for setup, 20 for the test, 10 for writing the result.

## Placeholders: fill these in first

`<rdns>` is your reverse-DNS prefix, for example `com.example`. `<TEAMID>` is your 10-character Team ID (developer.apple.com → Account → Membership details).

| Where | What to put there |
|---|---|
| `PushCheck-iOS/SpikeConfig.swift`, `containerID` | `iCloud.<rdns>.levels` |
| `PushCheck-iOS/PushCheck.entitlements`, container ID | `iCloud.<rdns>.levels` |
| `PushCheck-Mac/SpikeConfig.swift`, `containerID` | `iCloud.<rdns>.levels` |
| `PushCheck-Mac/PushCheckMac.entitlements`, container ID | `iCloud.<rdns>.levels` |
| Developer portal: iCloud container (step 1) | `iCloud.<rdns>.levels` |
| Developer portal: App ID (step 1) | `<rdns>.levels` |
| Xcode, both projects: Organization Identifier | `<rdns>` |
| Xcode, both projects: Bundle Identifier | `<rdns>.levels` |
| Xcode, both projects: Signing → Team | your team (its ID is `<TEAMID>`) |

`<TEAMID>` is not typed into any file. Xcode takes it from the Team you pick.
The container in the Swift file and in the entitlements file must be the same text. A mismatch gives a "permission" or "bad container" error.

Edit the files in a text editor, or in Xcode after you add them. In the `.entitlements` files, `<rdns>` is written as `&lt;rdns&gt;`. Replace the whole `&lt;rdns&gt;` with your prefix.

## Part A: Apple Developer portal (once)

1. Sign in at developer.apple.com → Account → Certificates, Identifiers & Profiles.
2. Identifiers → **+** → **iCloud Containers** → Continue. Identifier: `iCloud.<rdns>.levels`. Description: Levels. Register.
3. Identifiers → **+** → **App IDs** → **App** → Continue.
   - Description: Levels.
   - Bundle ID: **Explicit**, `<rdns>.levels`.
   - Tick **iCloud**, choose **Include CloudKit support**.
   - Tick **Push Notifications**.
   - Continue → Register.
4. Open the new App ID again. Next to iCloud, press **Configure** (or Edit). Tick `iCloud.<rdns>.levels`. Save.
5. The iPhone and the Mac app use the same App ID (ADR-0003). If Xcode later refuses that for the Mac, use `<rdns>.levels.mac` for the Mac app only. The spike still works: what matters is the container.

Xcode with automatic signing can also create these for you. Doing it here first makes errors easier to read.

## Part B: install and sign in to Xcode (once)

1. Open Xcode. Accept the licence. Let it install the iOS platform when it asks (Xcode → Settings → Components if it doesn't).
2. Xcode → Settings → **Accounts** → **+** → Apple ID. Sign in with the Apple ID of your paid developer team.
3. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on. The iPhone restarts.
4. Connect the iPhone by cable. Tap **Trust** on the iPhone.
5. Both the iPhone and the Mac must be signed in to iCloud with **the same Apple ID**.

Make the Xcode projects **outside the repo**, for example in `~/Desktop/SpikeProjects`. Only this `Spike/` folder is kept in git.

How Xcode 26 handles files: a new project uses a **synchronized folder** (the blue folder icon in the left sidebar). Every file you put in that folder on disk is part of the app. So you add files by copying them into the folder in Finder. Xcode picks them up by itself. If you drag files onto the sidebar instead, a dialog opens: set **Action** to **Copy files to destination** and tick the target.

## Part C: the Mac project

1. Xcode → File → New → Project → **macOS** → **App** → Next.
2. Product Name: `PushCheckMac`. Team: your team. Organization Identifier: `<rdns>`. Interface: SwiftUI. Language: Swift. Testing System: None. Storage: None. Next. Save in `~/Desktop/SpikeProjects`.
3. Click the blue project icon at the top left. Select the target **PushCheckMac**.
4. **General** tab:
   - Bundle Identifier: `<rdns>.levels`.
   - Minimum Deployments: macOS 26.0.
   - Frameworks, Libraries, and Embedded Content: press **+**, choose `CloudKit.framework`, Add. (ADR-0013: a sandboxed app must link CloudKit itself, or it gets CKError 6.)
5. **Build Settings** tab: search "Swift Language Version". Set it to **Swift 6**.
6. **Signing & Capabilities** tab:
   - Automatically manage signing: on. Team: your team.
   - App Sandbox is already there. Under Network, tick **Outgoing Connections (Client)**.
   - Press **+ Capability** → **iCloud**. Tick **CloudKit**. Under Containers, tick `iCloud.<rdns>.levels` (press **+** to add it if it isn't listed).
   - Xcode has now made a file `PushCheckMac.entitlements`.
   - A **Push Notifications** line may also appear in Signing & Capabilities. Ignore it. The Mac app doesn't need push, and our entitlements file has no push entry.
7. In Finder, open `~/Desktop/SpikeProjects/PushCheckMac/PushCheckMac/`. Copy `Spike/PushCheck-Mac/PushCheckMac.entitlements` from the repo into it. Choose **Replace**.
8. In Xcode's left sidebar, right-click `ContentView.swift` → Delete → Move to Trash. Do the same for `PushCheckMacApp.swift`.
9. In Finder, copy the four `.swift` files from `Spike/PushCheck-Mac/` into the same folder `~/Desktop/SpikeProjects/PushCheckMac/PushCheckMac/`. Xcode shows them in the sidebar by itself.
10. Check `<rdns>` is replaced in `SpikeConfig.swift` and in the entitlements file.
11. Signing & Capabilities must show no red error. A Push Notifications line without a matching entitlement is fine (step 6).
12. Press **⌘R**. The window shows **Signed container environment**. It is read from the app's own signature. Green "Production" is what the test needs.

## Part D: deploy the schema to Production (ADR-0018 §6)

Production only accepts record types that are deployed there. You create the type in Development once, then deploy it.

Skip this part if CloudKit Console → your container → **Production** → Schema → Record Types already shows `DeviceBattery` with the 13 fields below.

> Production schema is add-only. Fields can never be removed or renamed. This deploys the ADR-0005 fields as they are now. If ADR-0005 is still being changed, stop and ask first.

1. In Xcode, open `PushCheckMac.entitlements`. Change `Production` to **`Development`**. Save. (Temporary.)
2. Press **⌘R**. The Mac app opens. If macOS asks about iCloud or keychain access, allow it.
3. Check the window says **Signed container environment: Development** (red). Press **Write DeviceBattery record** once. The list shows `SETUP | zone Levels ready` and `WRITE | #1 saved`.
4. Open icloud.developer.apple.com → **CloudKit Database** → pick `iCloud.<rdns>.levels` → environment **Development** → Schema → **Record Types** → `DeviceBattery`. Check the fields:
   - Int64: `schemaVersion`, `level`, `isCharging`, `isPluggedIn`, `isLowPowerMode`
   - String: `deviceId`, `type`, `parentDeviceId`, `accessoryKind`, `accessoryGroupId`, `component`
   - Date/Time: `updatedAt`
   - Encrypted String: `name`
5. Back in the Mac app, press **Delete test record**.
6. In CloudKit Console, press **Deploy Schema Changes…** (bottom left). Read the list. Press **Deploy**.
7. Switch the Console to **Production** → Schema → Record Types. `DeviceBattery` is there with the same fields.
8. In Xcode, change the entitlement back to **`Production`**. Save. Press **■** (Stop), then **⌘R** again. The window must now say **Signed container environment: Production** (green).

This spike needs no extra indexes. A database subscription and a zone fetch don't use them.

## Part E: the iPhone project

1. Xcode → File → New → Project → **iOS** → **App** → Next.
2. Product Name: `PushCheck`. Team: your team. Organization Identifier: `<rdns>`. Interface: SwiftUI. Language: Swift. Testing System: None. Storage: None. Save in `~/Desktop/SpikeProjects`.
3. Select the target **PushCheck**.
4. **General**: Bundle Identifier `<rdns>.levels`. Minimum Deployments iOS 26.0.
5. **Build Settings**: Swift Language Version → **Swift 6**.
6. **Signing & Capabilities**:
   - Automatically manage signing: on. Team: your team.
   - **+ Capability** → **iCloud**. Tick **CloudKit**. Tick `iCloud.<rdns>.levels`.
   - **+ Capability** → **Push Notifications**.
   - **+ Capability** → **Background Modes**. Tick **Remote notifications**.
   - Xcode has now made `PushCheck.entitlements`, and usually an `Info.plist`, in the `PushCheck` folder.
7. In Finder, open `~/Desktop/SpikeProjects/PushCheck/PushCheck/`. Copy these two files from `Spike/PushCheck-iOS/` into it and choose **Replace**:
   - `PushCheck.entitlements` (Debug: `aps-environment = development`, container environment `Production`)
   - `Info.plist` (`UIBackgroundModes = remote-notification`, plus `ITSAppUsesNonExemptEncryption = NO` for TestFlight)
   - If Xcode made no `Info.plist`: copy ours in anyway. Then Build Settings → search "Info.plist File" → set it to `PushCheck/Info.plist`.
   - Debug and Release both use this one entitlements file. For TestFlight, Xcode's export re-signs `aps-environment` to `production` (Part H checks this).
8. Delete the template `ContentView.swift` and `PushCheckApp.swift` (right-click → Delete → Move to Trash).
9. In Finder, copy the five `.swift` files from `Spike/PushCheck-iOS/` into `~/Desktop/SpikeProjects/PushCheck/PushCheck/`. Xcode shows them in the sidebar by itself.
10. Check `<rdns>` is replaced in `SpikeConfig.swift` and in `PushCheck.entitlements`.
11. At the top of Xcode, pick your iPhone as the run destination. Press **⌘R**.
12. On the iPhone the app shows a log. Wait until you see all of these:
    - `APNS | registered`
    - `SETUP | account status: available`
    - `SETUP | zone saved: Levels`
    - `SETUP | subscription saved: levels-private-db`
    - `SETUP | done, ready for the test`
    Any `ERROR` line means stop and fix it first (see "If something fails").
13. Optional check of the signed entitlements. Xcode → Product → **Show Build Folder in Finder** → `Products/Debug-iphoneos/PushCheck.app`. In Terminal type `codesign -d --entitlements - ` (with a space at the end), drag the `.app` in, press Return. You should see `aps-environment` = `development` and `com.apple.developer.icloud-container-environment` = `Production`.

If the build fails with "Multiple commands produce … Info.plist": select `Info.plist` in the sidebar, open the right panel, and untick the PushCheck target under Target Membership.

## Part F: the test (SPIKE-001 R3, exactly)

Before you start:

1. iPhone: Low Power Mode **off** (Settings → Battery). Focus **off** (Control Center).
2. iPhone and Mac: on Wi-Fi or mobile data, awake, both signed in to the same iCloud.
3. Mac: the PushCheckMac app is running and says **Signed container environment: Production** (Part D step 8).

The run:

4. In Xcode, press **■** (Stop) on the iPhone run. Unplug the iPhone cable. No debugger may be attached.
5. On the iPhone, open **PushCheck from the Home Screen** (not from Xcode).
6. Wait for `SETUP | done, ready for the test`.
7. Swipe up to go to the Home Screen. **Don't** swipe the app away in the app switcher (that is a force-quit, and iOS then drops pushes).
8. Lock the iPhone with the side button. Leave it locked until step 13.
9. On the Mac, press **Write DeviceBattery record**. Write #1. Start a 5-minute timer.
   - While the timer runs, check the write reached **Production**. CloudKit Console → your container → **Production** → Records → Database **Private**, Zone **Levels** → look up the record by its name `5a1e7e57-0001-4001-8001-5b1ce0000001`. It must be there, with a fresh `updatedAt`.
   - If it isn't there, the Mac is still on Development. Stop: fix Part D step 8 and start Part F again. Don't go on to the TestFlight check.
   - If the Console refuses the lookup because `recordName` isn't queryable, skip this check. The green "Production" line in the Mac app is enough.
10. When the timer ends (5 minutes or more), press the button again. Write #2. Start a new 5-minute timer.
11. When it ends, press the button a third time. Write #3.
12. Wait 5 more minutes.
13. Unlock the iPhone. Open PushCheck.
14. Press **Share** (AirDrop to the Mac, or save to Notes) or **Copy**. On the Mac press **Copy log** and paste it next to the iPhone log.

## Part G: read the result (SPIKE-001 R4)

1. In the Mac log, find the three `WRITE | #n saved` lines. Note their times.
2. In the iPhone log, find lines like:
   `2026-11-24 10:15:03.412 +04:00 | PUSH | subscriptionID=levels-private-db type=database state=background`
3. A write counts as delivered if a `PUSH … levels-private-db` line has a time **after** that write and **within 5 minutes** of it.
   Only count PUSH lines from before you unlocked the iPhone in step 13. `PHASE | active` shows when you opened the app.
   `state=background` means the push woke the app in the background. That is what we want.
4. Decide:
   - **Pass**: at least one write was delivered. Go to Part I.
   - **Zero pushes**: not decided yet. Run the TestFlight control in Part H.

Throttling is normal. One push out of three is a Pass.

## Part H: TestFlight control (only after zero pushes)

This runs the same iPhone code as a TestFlight build, which uses `aps-environment = production`.

1. **Save the Debug log first** (Share or Copy). Installing from TestFlight replaces the app and its log.
2. App Store Connect (appstoreconnect.apple.com) → Apps → **+** → New App. Platform iOS. Name: anything free, for example "Levels Push Check" (you can rename it later). Bundle ID: `<rdns>.levels`. SKU: `levels`. Create.
3. App icon (an upload without one is refused). In Xcode's sidebar open **Assets** → **AppIcon**. Drop any 1024×1024 PNG into the empty slot.
4. Target PushCheck → **General** → Identity → **Build**. Raise the number before each upload (1, then 2, and so on). App Store Connect refuses a build number it has already seen.
5. Run destination: **Any iOS Device (arm64)**. Product → **Archive**. The entitlements file stays the same (`development`).
6. In the Organizer window: **Distribute App** → **TestFlight Internal Only** → Distribute. Xcode re-signs the app for distribution. That sets `aps-environment` to `production`.
7. Check it. In the Organizer, use Distribute App → **Custom** → **App Store Connect** → **Export** to get a re-signed copy. Rename the exported `.ipa` to `.zip`, unzip it, and find `Payload/PushCheck.app`. In Terminal type `codesign -d --entitlements - ` (with a space), drag the `.app` in, press Return.
   - The exported `.app` must show `aps-environment` = `production` and `com.apple.developer.icloud-container-environment` = `Production`.
   - The `.app` inside the archive itself is not re-signed yet and still shows `development`. Only the exported copy counts.
8. Wait for the "ready to test" email (often 10–30 minutes).
9. App Store Connect → your app → TestFlight → Internal Testing → add a group with yourself.
10. On the iPhone, install the **TestFlight** app. Install PushCheck from it.
11. Open PushCheck from the Home Screen. Wait for `SETUP | done` and `APNS | registered`.
12. Repeat Part F steps 7 to 14 (background, lock, 3 Mac writes 5 minutes apart, wait, read).
13. Decide:
    - TestFlight build gets at least one push, the Debug build got none: **Fail**.
    - TestFlight build also gets none: **Blocked**. The setup is wrong, not the push environment. Fix it (below) and run Part F again.

## If something fails

- `ERROR | account status …` or `notAuthenticated`: sign in to iCloud on that device. Check iCloud is allowed for the app (Settings → your name → iCloud → Apps Using iCloud).
- `CKError 6` or "Error connecting to CloudKit daemon" on the Mac: `CloudKit.framework` is not linked (Part C step 4). Check with `otool -L` on the app binary in `PushCheckMac.app/Contents/MacOS/`.
- "Bad container", "permission failure" or "invalid container": the container text differs between `SpikeConfig.swift`, the entitlements file and the portal.
- Mac `ERROR | save failed` with "unknown record type" or "cannot create new type": the schema is not in Production (Part D), or the entitlement still says Development.
- `ERROR | APNs registration failed`: Push Notifications capability missing, or the App ID lacks Push. Check Part A step 3.
- Server subscriptions list doesn't show `levels-private-db`: tap **Run setup** and read the error.
- No PUSH lines at all, and no `PHASE` lines either: the app may have been force-quit. Open it from the Home Screen and repeat Part F.

## Part I: record the result (SPIKE-001 R7)

Write it in two places. Ask Claude to do it if you like: paste both logs and say Pass, Fail or Blocked.

1. Replace "(Fill in after the run.)" at the end of `docs/specs/SPIKE-001-debug-build-push-check.md` with:

   ```markdown
   - **Result:** Pass | Fail | Blocked
   - **Date:** 2026-11-__
   - **iPhone:** <model>, iOS <version> (<build>)   ← Settings → General → About → iOS Version
   - **Mac:** <model>, macOS <version> (<build>)    ← Apple menu → About This Mac
   - **iPhone build:** Debug from Xcode, aps-environment development, container Production
   - **Mac writes:** #1 hh:mm:ss, #2 hh:mm:ss, #3 hh:mm:ss
   - **Pushes received:** hh:mm:ss (+N s after write #n), … or "none"
   - **TestFlight control:** not run | N pushes at hh:mm:ss | none
   - **Branch:** R5 (Xcode debug builds daily) | R6 (TestFlight daily, Xcode Cloud at the start of v0.1) | none yet (Blocked: <what was wrong>)
   ```

2. Add a row to the "Owner decisions" table in `docs/decisions-log.md`, after row I:

   ```markdown
   | 2026-11-__ | J | SPIKE-001 result: <Pass/Fail>. <One sentence: daily iPhone build comes from Xcode debug builds (R5) / TestFlight, Xcode Cloud set up at the start of v0.1 (R6)>. | [SPIKE-001](specs/SPIKE-001-debug-build-push-check.md) Result, [ADR-0018](adr/0018-testing-strategy.md) §5 |
   ```

   A Blocked run gets no row yet. Fix the setup and run again.

3. Tick AC1 and AC2 in SPIKE-001.

## Clean up

1. Mac app: press **Delete test record** (it deletes the Production test record).
2. Leave the `Levels` zone and the `levels-private-db` subscription. The real app uses the same ones.
3. The PushCheck app on the iPhone is replaced when the real Levels app is installed (same bundle ID). Or delete it now.
4. Delete `~/Desktop/SpikeProjects` and this `Spike/` folder when the result is recorded.

## NET-001 AC1: TLS-PSK on loopback (`TLSPSK-Mac/`)

Two throwaway Swift scripts from the NET-001 AC1 spike. `psk.swift` shows per-identity keys on the server (`multi`), the selection block (`sel`) and that keys added after start are not seen (`late`). `restart.swift` shows a rebuilt listener keeps its port and its open connections. Results are in NET-001 AC1. Delete after the real-hardware run of AC1.
