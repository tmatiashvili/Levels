# Setting up Levels.xcodeproj

Everything except the Xcode project file is already in the repo: target folders, Info.plists, entitlements, build settings (`Config/*.xcconfig`) and the `Shared/` package. These steps create `Levels.xcodeproj` around them. You need full Xcode 26 or later, signed in with your paid developer account (Xcode → Settings → Accounts).

Source of truth: [ADR-0003](docs/adr/0003-project-structure.md). Entitlement rules: [SYNC-001](docs/specs/SYNC-001-cloudkit-sync-engine.md), [MAC-001](docs/specs/MAC-001-mac-menu-bar-agent.md), [ADR-0013](docs/adr/0013-mac-distribution-and-sandbox.md).

## What you will end up with

| Target | Platform | Bundle ID | Shared products linked | Entitlements file (Debug / Release) | Embedded in |
|---|---|---|---|---|---|
| Levels-iOS | iOS (iPhone + iPad) | `<rdns>.levels` | LevelsModel, LevelsSync, LevelsReaders, LevelsUI, LevelsWidgetKit | `Levels-iOS/Levels-iOS.Debug.entitlements` / `Levels-iOS/Levels-iOS.Release.entitlements` | – |
| Levels-Mac | macOS | `<rdns>.levels` | all five + `CloudKit.framework` | `Levels-Mac/Levels-Mac.Debug.entitlements` / `Levels-Mac/Levels-Mac.Release.entitlements` | – |
| Levels-Watch | watchOS | `<rdns>.levels.watchkitapp` | all five | `Levels-Watch/Levels-Watch.Debug.entitlements` / `Levels-Watch/Levels-Watch.Release.entitlements` | Levels-iOS |
| Widgets-iOS | iOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-iOS/Widgets-iOS.entitlements` (both) | Levels-iOS |
| Widgets-Mac | macOS | `<rdns>.levels.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Mac/Widgets-Mac.entitlements` (both) | Levels-Mac |
| Widgets-Watch | watchOS | `<rdns>.levels.watchkitapp.widgets` | LevelsModel, LevelsUI, LevelsWidgetKit | `Widgets-Watch/Widgets-Watch.entitlements` (both) | Levels-Watch |

Never link LevelsSync or LevelsReaders into a widget target (ADR-0003 §3, SYNC-001 AC17).

You type your Team ID and prefix in one place only: `Config/Levels.xcconfig`. Every other file uses build-setting variables that Xcode fills in at build time: `$(LEVELS_RDNS)`, `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(TeamIdentifierPrefix)` (your Team ID plus a dot) and `$(AppIdentifierPrefix)` (the same, for the keychain group). Don't replace those by hand.

## Steps

### A. Fill in the placeholders

1. Open `Config/Levels.xcconfig` in any editor.
2. Replace `<TEAMID>` with your Team ID (10 characters; Xcode → Settings → Accounts → your team, or developer.apple.com → Membership).
3. Replace `<rdns>` with your reverse-DNS prefix, for example `com.yourname`. Use lowercase letters, digits, dots and hyphens only.
4. Save. Don't commit your real values if the repo will ever be public; otherwise it's fine.

### B. Create the project

Xcode always creates template files next to a new project, so create it in a scratch folder and move only the project file.

5. In Xcode: File → New → Project → iOS → App → Next.
6. Product Name `Levels`, Team: yours, Organization Identifier: your `<rdns>`, Interface SwiftUI, Language Swift, Testing System None, Storage None. Next.
7. Save it in a new empty folder outside the repo, for example `~/Desktop/levels-scratch`. Untick "Create Git repository". Create.
8. Quit Xcode. In Finder, move `~/Desktop/levels-scratch/Levels/Levels.xcodeproj` into the repo root (next to `Shared/` and `SETUP.md`). Delete the scratch folder.
9. Open `Levels.xcodeproj` from the repo root. In the left sidebar (the Project navigator) the template's `Levels` folder is now missing (red or greyed). Right-click it → Delete.

### C. Name the first target and point the project at the xcconfig files

10. Click the blue project icon at the top of the sidebar. In the TARGETS list, double-click `Levels` and rename it `Levels-iOS`. If Xcode asks to rename the scheme too, accept; otherwise do it in Product → Scheme → Manage Schemes.
11. Drag the `Config` folder from Finder into the sidebar. In the dialog choose "Reference files in place" (or untick "Copy items if needed"), and **add it to no target**.
12. Select the project (not a target) → Info tab → Configurations. Open Debug and Release. On the line for the project itself choose `Levels` (the `Config/Levels.xcconfig` file). On the `Levels-iOS` line choose `Levels-iOS`.

### D. Add the other five targets

For each, use File → New → Target, pick the template, then press Finish. If Xcode offers to activate a new scheme, say Activate.

13. **Levels-Mac**: macOS → App. Product Name `Levels-Mac`, Interface SwiftUI.
14. **Levels-Watch**: watchOS → App. Product Name `Levels-Watch`, choose "Watch App for Existing iOS App" and Companion App `Levels-iOS`.
15. **Widgets-iOS**: iOS → Widget Extension. Product Name `Widgets-iOS`. Untick "Include Live Activity", "Include Control" and "Include Configuration App Intent". Embed in `Levels-iOS`. If asked to activate a scheme, Activate.
16. **Widgets-Mac**: macOS → Widget Extension. Product Name `Widgets-Mac`, same three boxes unticked, embed in `Levels-Mac`.
17. **Widgets-Watch**: watchOS → Widget Extension. Product Name `Widgets-Watch`, same boxes unticked, embed in `Levels-Watch`.
18. Each template wrote sample files into the repo, some into folders that already exist (for example `Levels-Mac/`), and the widget templates may overwrite our `Info.plist` files. Clean up in two parts:
    - In the sidebar, select each folder the templates added (everything except `Config`), right-click → Delete → **Remove Reference**. Never choose "Move to Trash" here: the folder may be one of ours.
    - In Terminal, from the repo root:
      ```sh
      git checkout -- Config Levels-iOS Levels-Mac Levels-Watch Widgets-iOS Widgets-Mac Widgets-Watch
      git clean -n -d -e Levels.xcodeproj
      ```
      The first line puts back any file a template overwrote. The second only lists the new files the templates made; it leaves out the project file. If the list holds only template files, run `git clean -f -d -e Levels.xcodeproj` to delete them. Always keep the `-e Levels.xcodeproj` part, or git deletes your new project. Afterwards `git status` shows only `Levels.xcodeproj` as new.
19. Back in project → Info → Configurations, set each new target's line to its xcconfig (`Levels-Mac`, `Levels-Watch`, `Widgets-iOS`, `Widgets-Mac`, `Widgets-Watch`) for both Debug and Release.

### E. Remove template settings that would override the xcconfig files

Settings typed into a target win over its xcconfig file, and the templates type a lot of them.

20. Select a target → Build Settings → choose "All" and "Levels" (not "Combined") at the top. Settings set on the target show in bold in the target's column.
21. For each target, find these settings and, if bold in the target column, select the row and press Delete (it falls back to the xcconfig value): `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`, `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE`, every `INFOPLIST_KEY_…`, `CODE_SIGN_ENTITLEMENTS`, `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `IPHONEOS_DEPLOYMENT_TARGET`, `MACOSX_DEPLOYMENT_TARGET`, `WATCHOS_DEPLOYMENT_TARGET`, `SWIFT_VERSION`, `SWIFT_STRICT_CONCURRENCY`, `SDKROOT`, `SUPPORTED_PLATFORMS`, `TARGETED_DEVICE_FAMILY`, `LD_RUNPATH_SEARCH_PATHS`, `SKIP_INSTALL`, `ENABLE_HARDENED_RUNTIME`, `ENABLE_APP_SANDBOX`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_USER_SELECTED_FILES`. The search box at the top right of Build Settings finds each one.
22. `ENABLE_USER_SELECTED_FILES` on the two Mac targets matters most: if it stays at "Read Only", Xcode adds a file-access entitlement that MAC-001 doesn't allow.

### F. Add the target folders as synchronized folders

23. From Finder, drag `Levels-iOS` into the sidebar. In the dialog choose "Create folders" (this makes a synchronized folder, shown with a blue folder icon), and tick only the target `Levels-iOS`.
24. Do the same for each folder, ticking only its own target: `Levels-Mac` → Levels-Mac, `Levels-Watch` → Levels-Watch, `Widgets-iOS` → Widgets-iOS, `Widgets-Mac` → Widgets-Mac, `Widgets-Watch` → Widgets-Watch.
25. Files you add to these folders later join the target by themselves. The Info.plist and entitlements files must not be copied into the app as resources: for each folder, select it in the sidebar, open the right-hand inspector, and under Target Membership → Exceptions (or "Build Phase membership exceptions") make sure `Info.plist` and the `.entitlements` files are excluded. If a build later fails with "Multiple commands produce …/Info.plist", this is the fix.

### G. Add the Shared package and link products

26. File → Add Package Dependencies → Add Local… → select the repo's `Shared` folder → Add Package. When asked which target gets which product, choose "None" for all; you'll link them per target next.
27. For each target: select it → General → "Frameworks, Libraries, and Embedded Content" → + → pick the products listed in the table above (under the Shared package).
28. `Levels-Mac` only: also add `CloudKit.framework` there (search "CloudKit"). The macOS 26 sandbox blocks CloudKit unless the framework is linked explicitly (ADR-0013).
29. Check the embedding: `Levels-iOS` → General → "Frameworks, Libraries, and Embedded Content" (or Build Phases → "Embed Foundation Extensions" / "Embed Watch Content") lists `LevelsWidgets.appex` and the watch app; `Levels-Mac` lists `LevelsWidgets.appex`; `Levels-Watch` lists `LevelsWatchWidgets.appex`.

### H. Signing

30. For each target → Signing & Capabilities: "Automatically manage signing" on, Team shows yours (it comes from the xcconfig). Xcode reads the checked-in entitlements files and lists the capabilities: iCloud (CloudKit), Push Notifications, App Groups, Keychain Sharing, Background Modes, and for Mac App Sandbox and Hardened Runtime.
31. Don't add capabilities with "+ Capability" if they're already listed; that can create a second entitlements file. If the iCloud section shows the container `iCloud.<rdns>.levels` unticked or red, tick it (Xcode registers it with Apple). Do the same for the App Group `group.<rdns>.levels` on the iOS and watch targets. The Mac group `<TEAMID>.<rdns>.levels` needs no registration.
32. If Xcode rewrites an entitlements file, compare with `git diff`. The only allowed differences are ones you meant to make; restore the rest with `git checkout -- <file>`.

### I. Schemes and building

33. Product → Scheme → Manage Schemes: keep one scheme per target (`Levels-iOS`, `Levels-Mac`, `Levels-Watch`, `Widgets-iOS`, `Widgets-Mac`, `Widgets-Watch`) and tick "Shared" for each so they're checked in.
34. Add a scheme `Levels-All` (ADR-0003 §7): New Scheme → Target `Levels-iOS` → then Edit Scheme → Build → + add `Levels-Mac` and `Levels-Watch`. Tick Shared.
35. Build each app scheme once (⌘B), picking a destination in the toolbar: `Levels-iOS` with an iPhone simulator, `Levels-Watch` with a watch simulator, `Levels-Mac` with "My Mac". Each widget is built with its app.
36. Run `Levels-Mac`: no Dock icon appears and a battery icon appears in the menu bar. That is the expected placeholder.
37. Commit `Levels.xcodeproj` (the `xcuserdata/` inside it is already ignored).

## Notes

- **Debug vs Release push:** Debug entitlements use `aps-environment = development`, Release `production` (owner decision I). The CloudKit environment is `Production` in both (decision C). Whether a Debug build still gets pushes is what SPIKE-001 checks first.
- **Mac sandbox:** on for v0.1–v0.2 (ADR-0013). At v0.3 MAC-003 turns it off for the Developer ID build: set `com.apple.security.app-sandbox` to false in `Levels-Mac/Levels-Mac.Release.entitlements` and `ENABLE_APP_SANDBOX = NO` in `Config/Levels-Mac.xcconfig`, together.
- **Release check for the Mac:** after exporting, `codesign -d --entitlements - Levels.app` must match `Levels-Mac/Levels-Mac.Release.entitlements` with the variables filled in, and `otool -L Levels.app/Contents/MacOS/Levels` must list CloudKit (MAC-001 AC11).
