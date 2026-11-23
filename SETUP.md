# Setting up Levels.xcodeproj

`Levels.xcodeproj` is in the repo. For now it holds the two Mac targets only: `Levels-Mac` and `Widgets-Mac`. The iOS and watch targets are added later, when the owner joins the paid Apple Developer Program. Steps for that are below.

Source of truth: [ADR-0003](docs/adr/0003-project-structure.md). Entitlement rules: [SYNC-001](docs/specs/SYNC-001-cloudkit-sync-engine.md), [MAC-001](docs/specs/MAC-001-mac-menu-bar-agent.md), [ADR-0013](docs/adr/0013-mac-distribution-and-sandbox.md).

You need full Xcode 26 or later (the project was made and checked with Xcode 27.2), signed in to the team in `Config/Levels.xcconfig` (Xcode → Settings → Accounts).

## Targets

| Target | Status | Platform | Bundle ID | Shared products linked | Entitlements file (Debug and Release) | Embedded in |
|---|---|---|---|---|---|---|
| Levels-Mac | **in the project** | macOS | `<rdns>.levels` | all five + `CloudKit.framework` | `Levels-Mac/Levels-Mac.entitlements` | – |
| Widgets-Mac | **in the project** | macOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Mac/Widgets-Mac.entitlements` | Levels-Mac |
| Levels-iOS | later | iOS (iPhone + iPad) | `<rdns>.levels` | LevelsModel, LevelsSync, LevelsReaders, LevelsUI, LevelsWidgetKit | `Levels-iOS/Levels-iOS.entitlements` | – |
| Levels-Watch | later | watchOS | `<rdns>.levels.watchkitapp` | all five | `Levels-Watch/Levels-Watch.entitlements` | Levels-iOS |
| Widgets-iOS | later | iOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-iOS/Widgets-iOS.entitlements` | Levels-iOS |
| Widgets-Watch | later | watchOS | `<rdns>.levels.watchkitapp.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Watch/Widgets-Watch.entitlements` | Levels-Watch |

Never link LevelsSync or LevelsReaders into a widget target (ADR-0003 §3, SYNC-001 AC17).

The Team ID and prefix live in one place: `Config/Levels.xcconfig` (now `N5P82JNFSC` and `com.tmatiashvili`). Every other file uses build-setting variables that Xcode fills in at build time: `$(LEVELS_RDNS)`, `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(TeamIdentifierPrefix)` (Team ID plus a dot) and `$(AppIdentifierPrefix)` (the same, for the keychain group). Don't replace those by hand.

## How the project is set up

The project file was written by hand, without a generator (ADR-0003). If you change it in Xcode, check `git diff` before committing.

- **Synchronized folders:** `Levels-Mac/` and `Widgets-Mac/` are synchronized folders (blue folder icon). Files you add there join their target by themselves.
- **Info.plist:** each folder has a membership exception for `Info.plist`, so it is not copied in as a resource. The xcconfig points at it through `INFOPLIST_FILE`.
- **xcconfig files:** the project uses `Config/Levels.xcconfig` for Debug and Release. Each target uses its own file (`Levels-Mac`, `Widgets-Mac`). The target build settings in the project are empty, so the xcconfig files decide everything.
- **Shared package:** `Shared/` is a local package. `Levels-Mac` links all five products and `CloudKit.framework`. `Widgets-Mac` links LevelsModel, LevelsUI and LevelsWidgetKit only.
- **Embedding:** `Levels-Mac` has an "Embed Foundation Extensions" phase that copies `LevelsWidgets.appex` into `Levels.app/Contents/PlugIns/`.
- **Schemes:** `Levels-Mac` and `Widgets-Mac` are shared schemes in `Levels.xcodeproj/xcshareddata/xcschemes/`. Xcode also shows a scheme for each package product.

Build from the command line:

```sh
xcodebuild -project Levels.xcodeproj -scheme Levels-Mac -configuration Debug -allowProvisioningUpdates build
```

Run `Levels-Mac` from Xcode with "My Mac": no Dock icon appears and a battery icon appears in the menu bar. That is the expected placeholder.

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

What else the free team means:

- The profile Xcode makes lasts 7 days and lists only this Mac. Build again at least once a week, or the app may stop launching.
- The build is development-signed only. There is no Developer ID export and no notarization, so the app runs only on this Mac.
- No CloudKit and no push, so no sync between devices. Code must not create a `CKContainer` while the iCloud entitlement is missing, because CloudKit stops the app when the entitlement is missing. `CloudKit.framework` is still linked (ADR-0013); linking alone is harmless.
- `registerForRemoteNotifications()` fails without the push entitlement. MAC-001 R8 already says to log and continue.

When the owner pays, put these keys back into `Levels-Mac/Levels-Mac.entitlements` (values from the MAC-001 table), change `DEVELOPMENT_TEAM` to the paid Team ID and build again:

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

## Adding the iOS and watch targets (later)

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
- **Mac sandbox:** on for v0.1–v0.2 (ADR-0013). At v0.3 MAC-003 turns it off for the Developer ID build: add `ENABLE_APP_SANDBOX[config=Release] = NO` to `Config/Levels-Mac.xcconfig`, so only the Release (Developer ID) build loses the sandbox (ADR-0013). Because `Levels-Mac/Levels-Mac.entitlements` sets `com.apple.security.app-sandbox = true` for both configurations, MAC-003 must also make the entitlements match: either a Release-only entitlements file without the sandbox key, or move the sandbox key out of the file and leave it to `ENABLE_APP_SANDBOX`. MAC-001 AC11 compares the exported entitlements with the table.
- **Release check for the Mac:** after exporting, `codesign -d --entitlements - Levels.app` must match `Levels-Mac/Levels-Mac.entitlements` with the variables filled in and `com.apple.developer.aps-environment` = `production`, and `otool -L Levels.app/Contents/MacOS/Levels` must list CloudKit (MAC-001 AC11). Run `otool` on a Release build: in a Debug build the code sits in `Levels.debug.dylib`, so CloudKit shows there and not in the `Levels` stub.
