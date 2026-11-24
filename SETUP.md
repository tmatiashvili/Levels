# Setting up Levels.xcodeproj

`Levels.xcodeproj` is in the repo. It holds the two Mac targets (`Levels-Mac`, `Widgets-Mac`) and, since 2026-11-24, the iPhone app, its widget and its unit tests (`Levels-iOS`, `Widgets-iOS`, `Levels-iOSTests`), all signed with the free Personal Team (owner decision M). The watch targets are added later; steps for that are below.

Source of truth: [ADR-0003](docs/adr/0003-project-structure.md). Entitlement rules: [SYNC-001](docs/specs/SYNC-001-cloudkit-sync-engine.md), [MAC-001](docs/specs/MAC-001-mac-menu-bar-agent.md), [ADR-0013](docs/adr/0013-mac-distribution-and-sandbox.md).

You need full Xcode 26 or later (the project was made and checked with Xcode 27.2), signed in to the team in `Config/Levels.xcconfig` (Xcode → Settings → Accounts).

## Targets

| Target | Status | Platform | Bundle ID | Shared products linked | Entitlements file (Debug and Release) | Embedded in |
|---|---|---|---|---|---|---|
| Levels-Mac | **in the project** | macOS | `<rdns>.levels` | all five + `CloudKit.framework` | `Levels-Mac/Levels-Mac.entitlements` | – |
| Widgets-Mac | **in the project** | macOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Mac/Widgets-Mac.entitlements` | Levels-Mac |
| Levels-iOS | **in the project** | iOS (iPhone now; iPad later, UI-005) | `<rdns>.levels` | LevelsModel, LevelsSync, LevelsReaders, LevelsUI, LevelsWidgetKit | `Levels-iOS/Levels-iOS.entitlements` | – |
| Levels-Watch | later | watchOS | `<rdns>.levels.watchkitapp` | all five | `Levels-Watch/Levels-Watch.entitlements` | Levels-iOS |
| Widgets-iOS | **in the project** | iOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-iOS/Widgets-iOS.entitlements` | Levels-iOS |
| Levels-iOSTests | **in the project** | iOS Simulator | `<rdns>.levels.tests` | – (hosted in Levels-iOS) | – | – |
| Widgets-Watch | later | watchOS | `<rdns>.levels.watchkitapp.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Watch/Widgets-Watch.entitlements` | Levels-Watch |

Never link LevelsSync or LevelsReaders into a widget target (ADR-0003 §3, SYNC-001 AC17).

The Team ID and prefix live in one place: `Config/Levels.xcconfig` (now `N5P82JNFSC` and `com.tmatiashvili`). Every other file uses build-setting variables that Xcode fills in at build time: `$(LEVELS_RDNS)`, `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(TeamIdentifierPrefix)` (Team ID plus a dot) and `$(AppIdentifierPrefix)` (the same, for the keychain group). Don't replace those by hand.

## How the project is set up

The project file was written by hand, without a generator (ADR-0003). If you change it in Xcode, check `git diff` before committing.

- **Synchronized folders:** `Levels-Mac/`, `Widgets-Mac/`, `Levels-iOS/`, `Widgets-iOS/` and `Levels-iOSTests/` are synchronized folders (blue folder icon). Files you add there join their target by themselves.
- **Info.plist:** each folder has a membership exception for `Info.plist`, so it is not copied in as a resource. The xcconfig points at it through `INFOPLIST_FILE`.
- **xcconfig files:** the project uses `Config/Levels.xcconfig` for Debug and Release. Each target uses its own file (`Levels-Mac`, `Widgets-Mac`, `Levels-iOS`, `Widgets-iOS`, `Levels-iOSTests`). The target build settings in the project are empty, so the xcconfig files decide everything.
- **Shared package:** `Shared/` is a local package. `Levels-Mac` links all five products and `CloudKit.framework`. `Widgets-Mac` links LevelsModel, LevelsUI and LevelsWidgetKit only.
- **Embedding:** `Levels-Mac` has an "Embed Foundation Extensions" phase that copies `LevelsWidgets.appex` into `Levels.app/Contents/PlugIns/`.
- **Schemes:** `Levels-Mac` and `Widgets-Mac` are shared schemes in `Levels.xcodeproj/xcshareddata/xcschemes/`. Xcode also shows a scheme for each package product.

Build from the command line:

```sh
xcodebuild -project Levels.xcodeproj -scheme Levels-Mac -configuration Debug -allowProvisioningUpdates build
```

## Try it

The Mac app works today on the free team, local only: it shows this Mac's own battery in the menu bar, the popover and a desktop widget. Nothing syncs between devices yet.

1. **Get the app.** Either open `Levels.xcodeproj` in Xcode, pick the `Levels-Mac` scheme and "My Mac", and press ⌘R; or double-click a built copy (for example `~/Desktop/Levels-try/Levels.app`). There is no Dock icon: look for a full-battery symbol in the menu bar (with no other devices it shows no percentage).
2. **First launch** turns on Open at login (MAC-001 R6). Turn it off in Levels → ⋯ → Settings… if you don't want it.
3. **Use it.** Click the menu-bar item for the list; ⟳ or ⌘R refreshes. ⋯ has Settings, About and Quit. If the menu-bar item is hidden, open Levels again from Finder: Settings comes up.
4. **Add the widget.** Right-click the desktop → Edit Widgets…, search "Levels", drag the small or medium "Battery Levels" widget onto the desktop. Clicking it opens the Levels device window.
5. **Rebuild every week.** The free profile lasts 7 days. After that the app may stop launching: run `scripts/reinstall.sh` (see "Weekly reinstall").

### Connect your iPhone to the Mac

The Mac is the hub on your home Wi-Fi (owner decision M). Pair once:

1. **On the Mac:** click the Levels menu-bar item → ⋯ → Settings… → iPhone → **Pair iPhone…**. A 6-digit code shows for 2 minutes.
2. **On the iPhone:** open Levels → ⚙ Settings → Mac → **Connect to your Mac** (or tap **Connect** on the card at the top of the list), then **Continue**.
3. **Allow Local Network** when the iPhone asks ("Levels would like to find and connect to devices on your local network"). If you tapped Don't Allow: Settings → Privacy & Security → Local Network → Levels on.
4. **On the iPhone:** pick "Levels-…" (your Mac), type the 6-digit code from the Mac and tap **Connect**.
5. **On the Mac:** if macOS asks whether Levels may accept incoming network connections, click **Allow**.
6. **Compare the numbers.** Both screens now show a 6-digit confirmation number. The iPhone asks "Does your Mac show this number?"; the Mac asks "Does <your iPhone> show this number?".
   - Same number: tap **They match** on the iPhone and click **They match** on the Mac (either first). The iPhone says "Connected to <your Mac>"; the Mac says "Paired with <your iPhone>".
   - Different numbers: tap **Cancel** on either screen. Someone else may be trying to connect; nothing is saved. Get a new code and try again.
   - You have up to 2 minutes; after that, get a new code.
7. The iPhone and the Mac must be on the same Wi-Fi, with the Mac awake. Away from home the iPhone shows "Away from your Mac" and the last levels it got.

To undo: iPhone Settings → Mac → **Forget this Mac**; Mac Settings → iPhone → Remove.

What the free build does not do yet: devices beyond this Mac and one paired iPhone (needs iCloud), push, and a widget device picker. With no other devices the menu-bar label is the app symbol only (UI-004 R3), so it doesn't repeat the macOS battery item; with other devices it shows the lowest of them (UI-004 R1).

Check it worked: `log show --predicate 'subsystem BEGINSWITH "com.tmatiashvili"' --last 2m` shows `Report launch: <name> level=63 …` and, in Debug builds, the `snapshot.json` it wrote; compare with `pmset -g batt`. Terminal can't read `~/Library/Group Containers/<TEAMID>.com.tmatiashvili.levels/` directly (macOS protects other apps' group containers), which is why the Debug log prints the file.

## Try it on the iPhone

The iPhone app works on the free team with the Mac as its hub (owner decision M, NET-003/NET-004): it shows this iPhone's battery, and after pairing (see "Connect your iPhone to the Mac" above) the Mac's battery and its accessories, in the app and in Home Screen and Lock Screen widgets. The app updates live while it is open on the home Wi-Fi; the widgets read the cache the app writes and also ask the Mac themselves when that cache is older than 15 minutes.

1. **Build and install** (iPhone connected by cable or on the same Wi-Fi, Developer Mode on):
   ```sh
   xcodebuild -project Levels.xcodeproj -scheme Levels-iOS -configuration Debug \
     -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     -derivedDataPath /tmp/levels-ios build
   xcrun devicectl device install app --device <UDID> /tmp/levels-ios/Build/Products/Debug-iphoneos/Levels.app
   xcrun devicectl device process launch --device <UDID> com.tmatiashvili.levels
   ```
   Or pick the `Levels-iOS` scheme and the iPhone in Xcode and press ⌘R. `xcrun devicectl list devices` shows the UDID.
2. **Trust the developer once.** If the launch fails with "profile has not been explicitly trusted", open Settings → General → VPN & Device Management → Apple Development: <your Apple ID> → Trust. iOS forgets the trust when the last app of this developer is deleted, so it can come back after uninstalling.
3. **Use it.** The list shows this iPhone; pull down to refresh (reports `.userRefresh`). ⚙ opens Settings: rename, the Mac section (Connect, Pair again, Forget), Shortcuts setup, hidden devices, Remove all my data.
4. **Add widgets.** Home Screen: touch and hold → Edit → Add Widget → Levels → small, medium or large "Battery Levels". Lock Screen: touch and hold → Customize → Lock Screen → widgets → Levels (circular, rectangular, inline). A tap opens `levels://device/<uuid>`.
5. **Keep it fresh.** Set up the "Report Battery" automations (RPT-002; the app's hint card and Settings → "Set up Shortcuts automation" show the steps). Background refresh runs too, when iOS allows it.
6. **Rebuild every week.** The free profile lasts 7 days: run `scripts/reinstall.sh` (see "Weekly reinstall").
7. **Live levels on the Lock Screen** (LIVE-001). After pairing, tap the pin in the top-left of the Devices screen ("Pin levels to Lock Screen"), or turn on Settings → Lock Screen → "Show levels on Lock Screen". The Lock Screen, StandBy and the Dynamic Island then show this iPhone, the Mac and AirPods. Tap the pin again, turn the toggle off or swipe it away on the Lock Screen to end it; iOS ends it after 8 hours. If nothing appears, check Settings → Levels → Live Activities. On the free team it updates live while the app is open, and while the app is closed only when iOS runs the app (a "Report Battery" automation, a background refresh), so the levels can be old; its footer shows when they were read. After enrolling, the Mac pushes new levels (see "Widget push (after paying)").

Check it worked: `xcrun devicectl device copy from --device <UDID> --domain-type appGroupDataContainer --domain-identifier group.com.tmatiashvili.levels --source Levels/snapshot.json --destination /tmp/levels-snapshot.json` copies the cache the app wrote; it holds this iPhone's record with `"type":"iphone"` and the current level. Unit tests of the app target: `xcodebuild test -project Levels.xcodeproj -scheme Levels-iOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`.

## Weekly reinstall

The free profile lasts 7 days. One command rebuilds both apps and puts them back:

```sh
scripts/reinstall.sh
```

- **Mac:** builds `Levels-Mac` (Debug), quits Levels, replaces `~/Desktop/Levels-try/Levels.app`, registers the app and its widget again and opens it. Desktop widgets keep working because the app stays at the same path.
- **iPhone:** finds the connected iPhone, builds `Levels-iOS` (Debug) for it, installs it with `devicectl` and opens it. If no iPhone is reachable it says so and does only the Mac. Unlock the iPhone first.
- **At the end** it prints when the new profiles expire. Run it again before that date.
- **Options:** `--mac-only`, `--ios-only`, `--device <UDID>` (or `LEVELS_IPHONE_ID=<UDID>`) to pick an iPhone, `LEVELS_MAC_APP=<path>` for another Mac copy.
- Build output and logs go to `build/` in the repo (ignored by git). If a build fails, the script shows the errors and the log file.

Xcode reuses a profile that is still valid, so the printed date does not always move 7 days ahead. Use the date it prints.

## Free Personal Team (now)

Owner decision (2026-11-23): no paid Apple Developer Program for now. Xcode signs with the owner's free Personal Team. Tested on 2026-11-23 with Xcode 27.2 on macOS 27.2:

| Entitlement or setting | Levels-Mac | Widgets-Mac | Result |
|---|---|---|---|
| iCloud (CloudKit, container, environment) | removed | – | **Rejected.** Xcode can't make a profile: "Personal development teams … do not support the Push Notifications and iCloud capabilities." |
| Push (`com.apple.developer.aps-environment`) | removed | – | **Rejected**, same error. |
| App Group `$(TeamIdentifierPrefix)$(LEVELS_RDNS).levels` | kept | kept | Accepted. The Team ID–prefixed group needs no profile entry. The system created `~/Library/Group Containers/N5P82JNFSC.com.tmatiashvili.levels` on first launch. |
| App Sandbox | kept | kept | Accepted. The app runs sandboxed (container in `~/Library/Containers/`). |
| Hardened Runtime | on | on | Accepted (`flags=0x10000(runtime)`). |
| `keychain-access-groups` `$(AppIdentifierPrefix)$(LEVELS_RDNS).levels.shared` | kept | kept | Accepted. The free profile allows `N5P82JNFSC.*`. |
| `com.apple.security.network.client` | kept | – | Accepted. |

iPhone targets, tested on 2026-11-24 with Xcode 27.2 and iOS 27 on an iPhone 18 Pro Max:

| Entitlement or setting | Levels-iOS | Widgets-iOS | Result |
|---|---|---|---|
| iCloud (CloudKit, container, environment) | **removed** | – | Not tried again: rejected for the Mac with the same team (above). Put back from the paid-team block below. |
| Push (`aps-environment`) | **removed** | – | Same. `UIBackgroundModes` `remote-notification` removed too (nothing can push without it). |
| App Group `group.$(LEVELS_RDNS).levels` | kept | kept | Accepted; Xcode registered the group. App and widget share `Levels/snapshot.json` in it. |
| `keychain-access-groups` `$(AppIdentifierPrefix)$(LEVELS_RDNS).levels.shared` | kept | kept | Accepted. The free profile allows `N5P82JNFSC.*`. |
| `UIBackgroundModes` `fetch` + `BGTaskSchedulerPermittedIdentifiers` | kept | – | Accepted (needs no entitlement). |
| `NSLocalNetworkUsageDescription`, `NSBonjourServices` `_levels._tcp` | added | – | For the hub client (NET-003). No prompt yet: nothing browses until Connect exists. |
| App IDs | `<rdns>.levels` | `<rdns>.levels.widgets` | The same IDs the Mac targets already use, so no new App ID. The free team allows 10 App IDs per 7 days. |

What else the free team means:

- The profile Xcode makes lasts 7 days and lists only this Mac. Build again at least once a week, or the app may stop launching.
- The build is development-signed only. There is no Developer ID export and no notarization, so the app runs only on this Mac.
- No CloudKit and no push, so no sync between devices. Code must not create a `CKContainer` while the iCloud entitlement is missing, because CloudKit stops the app when the entitlement is missing. `CloudKit.framework` is still linked (ADR-0013); linking alone is harmless.
- `registerForRemoteNotifications()` fails without the push entitlement. MAC-001 R8 already says to log and continue.

When the owner pays, put these keys back into `Levels-Mac/Levels-Mac.entitlements` (values from the MAC-001 table), change `DEVELOPMENT_TEAM` to the paid Team ID and build again. For `Levels-iOS/Levels-iOS.entitlements` the same block applies with the key `aps-environment` instead of `com.apple.developer.aps-environment`, and `remote-notification` goes back into `UIBackgroundModes` in `Levels-iOS/Info.plist`:

```xml
<key>com.apple.developer.aps-environment</key>
<string>development</string>
<key>com.apple.developer.icloud-services</key>
<array>
	<string>CloudKit</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
	<string>iCloud.$(LEVELS_RDNS).levels</string>
</array>
<key>com.apple.developer.icloud-container-environment</key>
<string>Production</string>
```

A new Team ID changes `$(TeamIdentifierPrefix)`, so the App Group and keychain group get new IDs and the Mac starts with an empty cache. That is fine for a cache.

### Widget push (after paying)

The push-driven iPhone widget (ADR-0023, PUSH-001) is built but off. `LEVELS_PUSH_ENABLED = NO` in `Config/Levels.xcconfig` keeps the free-team build as it was: the old entitlements files, no push handler, no App Attest, no token upload, no push key, no relay calls. To turn it on:

1. Change `DEVELOPMENT_TEAM` to the paid Team ID. In the developer account, enable Push Notifications and App Attest on the iOS App ID (PUSH-001 R80).
2. Deploy the relay (`relay/`, PUSH-001 R81) and note its URL.
3. Set `LEVELS_PUSH_ENABLED = YES`. The iPhone app and widget then sign with `Config/Levels-iOS-Push.entitlements` and `Config/Widgets-iOS-Push.entitlements` (`aps-environment` = `development`; a TestFlight or App Store export rewrites it to `production`). Both need `aps-environment`: WidgetKit push asks for the capability on the app and the extension. Only the app's file has `com.apple.developer.devicecheck.appattest-environment` (`development`): the widget extension can't use App Attest. Apple's docs say TestFlight and App Store builds always use the production App Attest environment; check that on the first TestFlight build.
4. Set `LEVELS_PUSH_RELAY_URL` to the relay's base URL, written as `https:/$()/<host>` (xcconfig reads `//` as a comment). Both apps read it (Info.plist `LevelsPushRelayURL`). Empty keeps both from calling the relay: the Mac then answers 404 on `GET /v1/push-key`, so the iPhone never asks for a grant.

How the pieces connect (nothing to configure):

- The Mac makes a P-256 push key on first use, in the Keychain (`<rdns>.levels.push-key`). "Remove all pairings" replaces it.
- The iPhone app reads the Mac's public key over the paired hub (`GET /v1/push-key`), attests itself once with App Attest, asks the relay for a grant naming that key and its widget token, and sends tokens and grant to the Mac (`PUT /v1/push-tokens`, body v2). Its App Attest key ID, credential and last grant are in its Keychain (`<rdns>.levels.push`). The simulator has no App Attest, so push stays off there.
- The Mac signs each push (`Levels-Grant`, `Levels-Timestamp`, `Levels-Signature`). At most one push per iPhone per 15 minutes and 48 per day; plug-in, unplug and crossing the alert threshold go out at once but still count. No push while that iPhone's app is open.
- Live levels (LIVE-001): with push on, the app starts its Live Activity with a push token and sends that token to the Mac next to the widget's, under the same grant. The Mac pushes the new levels with priority 5 at most once a minute, and plug-in, unplug, 100 % and the alert threshold at once with priority 10; nothing while the app is open (it updates the activity itself). The activity needs no extra entitlement or capability beyond Push Notifications.
- An older Mac answers 404 on `GET /v1/push-key`, so a newer iPhone sends it nothing. An older iPhone's v1 upload (tokens only) is stored, but without a grant nothing is pushed.

The Mac itself needs no push entitlement. WidgetKit push needs no `remote-notification` background mode.

## Adding the watch targets (later)

> The iOS targets were added by hand on 2026-11-24 (see Targets). The steps below were written for all four targets; use them for `Levels-Watch` and `Widgets-Watch` only, and skip what concerns `Levels-iOS` and `Widgets-iOS`.

Do this only with the paid team: the iOS and watch apps need iCloud and push. The project and the Mac targets already exist, so these steps only add targets.

### A. Before you start

1. In `Config/Levels.xcconfig`, check `DEVELOPMENT_TEAM` is the paid Team ID.
2. Do the "When the owner pays" step above for the Mac entitlements.
3. Start from a clean tree: `git status` shows nothing to commit.

### B. Add the four targets

For each, open `Levels.xcodeproj`, use File → New → Target, pick the template, then press Finish. If Xcode offers to activate a new scheme, say Activate.

4. **Levels-iOS**: iOS → App. Product Name `Levels-iOS`, Interface SwiftUI, Testing System None, Storage None.
5. **Levels-Watch**: watchOS → App. Product Name `Levels-Watch`, choose "Watch App for Existing iOS App" and Companion App `Levels-iOS`.
6. **Widgets-iOS**: iOS → Widget Extension. Product Name `Widgets-iOS`. Untick "Include Live Activity", "Include Control" and "Include Configuration App Intent". Embed in `Levels-iOS`.
7. **Widgets-Watch**: watchOS → Widget Extension. Product Name `Widgets-Watch`, same three boxes unticked, embed in `Levels-Watch`.
8. The templates write sample files into the repo, some into folders that already exist (for example `Levels-iOS/`), and may overwrite our `Info.plist` files. Clean up in two parts:
    - In the sidebar, select each folder the templates added, right-click → Delete → **Remove Reference**. Never choose "Move to Trash": the folder may be one of ours. Don't touch `Config`, `Levels-Mac` or `Widgets-Mac`.
    - In Terminal, from the repo root:
      ```sh
      git checkout -- Config Levels-iOS Levels-Watch Widgets-iOS Widgets-Watch
      git clean -n -d
      ```
      The first line puts back any file a template overwrote. The second only lists new files the templates made. If the list holds only template files, run `git clean -f -d` to delete them. `Levels.xcodeproj` is tracked, so git clean leaves it alone. Afterwards `git status` shows only `Levels.xcodeproj/project.pbxproj` (and new schemes) as changed.

### C. Point the new targets at their xcconfig files

9. Select the project (not a target) → Info tab → Configurations. Open Debug and Release. On each new target's line choose its file: `Levels-iOS`, `Levels-Watch`, `Widgets-iOS`, `Widgets-Watch`. The project line already uses `Levels`. If a file doesn't show in the menu, it is listed in the `Config` group of the sidebar; check it's there.

### D. Remove template settings that would override the xcconfig files

Settings typed into a target win over its xcconfig file, and the templates type a lot of them.

10. Select a new target → Build Settings → choose "All" and "Levels" (not "Combined") at the top. Settings set on the target show in bold in the target's column.
11. For each new target, find these settings and, if bold in the target column, select the row and press Delete (it falls back to the xcconfig value): `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`, `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE`, every `INFOPLIST_KEY_…`, `CODE_SIGN_ENTITLEMENTS`, `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `IPHONEOS_DEPLOYMENT_TARGET`, `WATCHOS_DEPLOYMENT_TARGET`, `SWIFT_VERSION`, `SWIFT_STRICT_CONCURRENCY`, `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_APPROACHABLE_CONCURRENCY`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, `SDKROOT`, `SUPPORTED_PLATFORMS`, `TARGETED_DEVICE_FAMILY`, `LD_RUNPATH_SEARCH_PATHS`, `SKIP_INSTALL`. The search box at the top right of Build Settings finds each one. The Mac targets' settings are already empty; leave them so.
12. `SWIFT_DEFAULT_ACTOR_ISOLATION` matters most: Xcode templates set it to MainActor, but Levels uses `nonisolated`, like the Shared package (lead's call 15); UI types mark themselves `@MainActor`.

### E. Add the target folders as synchronized folders

13. From Finder, drag `Levels-iOS` into the sidebar. In the dialog choose "Create folders" (this makes a synchronized folder, shown with a blue folder icon), and tick only the target `Levels-iOS`.
14. Do the same for `Levels-Watch` → Levels-Watch, `Widgets-iOS` → Widgets-iOS, `Widgets-Watch` → Widgets-Watch.
15. For each of the four folders: open it in the sidebar, select `Info.plist`, open the File inspector (right-hand panel, first tab) and untick its target under Target Membership. Xcode records this as an exception for that folder, like the two Mac folders already have. If a build fails with "Multiple commands produce …/Info.plist", this step was missed.

### F. Link the Shared products

16. The `Shared` package is already in the project. For each new target: select it → General → "Frameworks, Libraries, and Embedded Content" → + → pick the products listed in the table above (under the Shared package).
17. Check the embedding: `Levels-iOS` → Build Phases lists `LevelsWidgets.appex` under "Embed Foundation Extensions" and the watch app under "Embed Watch Content"; `Levels-Watch` lists `LevelsWatchWidgets.appex`.

### G. Signing

18. For each target → Signing & Capabilities: "Automatically manage signing" on, Team shows yours (it comes from the xcconfig). Xcode reads the checked-in entitlements files and lists the capabilities: iCloud (CloudKit), Push Notifications, App Groups, Keychain Sharing, Background Modes.
    - **Levels-Watch check:** open its Background Modes section and look at the "Remote notifications" checkbox. Tick it if it isn't ticked, then run `git diff Levels-Watch/Info.plist`. Xcode writes the key it expects: `UIBackgroundModes` (what the repo has) or `WKBackgroundModes`. Keep whatever Xcode wrote and remove the other key, so the file holds exactly one of them with `remote-notification` (RPT-004's open assumption).
19. Don't add capabilities with "+ Capability" if they're already listed; that can create a second entitlements file. If the iCloud section shows the container `iCloud.<rdns>.levels` unticked or red, tick it (Xcode registers it with Apple). Do the same for the App Group `group.<rdns>.levels` on the iOS and watch targets. The Mac group `<TEAMID>.<rdns>.levels` needs no registration.
20. If Xcode rewrites an entitlements file, compare with `git diff`. The only allowed differences are ones you meant to make; restore the rest with `git checkout -- <file>`.

### H. Schemes and building

21. Product → Scheme → Manage Schemes: keep one scheme per target (`Levels-iOS`, `Levels-Mac`, `Levels-Watch`, `Widgets-iOS`, `Widgets-Mac`, `Widgets-Watch`) and tick "Shared" for each so they're checked in.
22. Add a scheme `Levels-All` (ADR-0003 §7): New Scheme → Target `Levels-iOS` → then Edit Scheme → Build → + add `Levels-Mac` and `Levels-Watch`. Tick Shared.
23. Build each app scheme once (⌘B): `Levels-iOS` with an iPhone simulator, `Levels-Watch` with a watch simulator, `Levels-Mac` with "My Mac". Each widget is built with its app.
24. Commit `Levels.xcodeproj` (the `xcuserdata/` inside it is already ignored).

## Notes

- **Push environment (paid team only):** each app has one entitlements file, used by Debug and Release, with `aps-environment = development` (`com.apple.developer.aps-environment` on Mac). Archiving with automatic signing uses the development profile, which allows only `development`. Exporting the archive for TestFlight, the App Store or Developer ID rewrites it to `production` (lead's call 14; owner decision I's outcome is unchanged). The CloudKit environment is `Production` in every build (decision C). Whether a Debug build still gets pushes is what SPIKE-001 checks first.
- **Check after every export:** run `codesign -d --entitlements - <exported .app>` (for an iOS or watch build, on the `.app` inside the exported `.ipa`'s `Payload/` folder). It must show `aps-environment` (Mac: `com.apple.developer.aps-environment`) = `production` and `com.apple.developer.icloud-container-environment` = `Production`.
- **Mac sandbox:** off for the Mac app in Debug and Release since MAC-003 was pulled forward (lead's call 16, ADR-0013 note): `ENABLE_APP_SANDBOX = NO` and `LEVELS_UNSANDBOXED` in `Config/Levels-Mac.xcconfig`, and no sandbox key in `Levels-Mac/Levels-Mac.entitlements`. AirPods levels come from `system_profiler`, which returns nothing inside the sandbox. The Mac widget stays sandboxed.
- **Release check for the Mac:** after exporting, `codesign -d --entitlements - Levels.app` must match `Levels-Mac/Levels-Mac.entitlements` with the variables filled in and `com.apple.developer.aps-environment` = `production`, and `otool -L Levels.app/Contents/MacOS/Levels` must list CloudKit (MAC-001 AC11). Run `otool` on a Release build: in a Debug build the code sits in `Levels.debug.dylib`, so CloudKit shows there and not in the `Levels` stub.
