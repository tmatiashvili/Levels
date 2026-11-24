#!/bin/bash
# Archive Levels for iPhone and export it for App Store Connect.
#
#   scripts/archive-ios.sh [--team <TEAMID>] [--build-number <N>] [--upload] [--cloud-signing]
#
#   --team          paid Apple Developer Program Team ID (or LEVELS_TEAM_ID). Default: the
#                   DEVELOPMENT_TEAM in Config/Levels.xcconfig.
#   --build-number  sets CURRENT_PROJECT_VERSION (CFBundleVersion) for this build. Every upload
#                   needs a build number higher than the last one for the same version.
#   --upload        upload to App Store Connect during export instead of writing an .ipa.
#
# Optional App Store Connect API key (for --upload without an Xcode account, e.g. CI):
#   LEVELS_ASC_KEY_PATH=/path/AuthKey_XXXX.p8 LEVELS_ASC_KEY_ID=XXXX LEVELS_ASC_ISSUER_ID=<uuid>
#
# Output: build/release/ios/Levels-iOS.xcarchive and export/Levels.ipa (gitignored).
#
# Needs the paid Apple Developer Program and an App Store Connect app record: a free
# Personal Team cannot sign for distribution, so the script stops before building when
# no "Apple Distribution" identity is in the keychain (pass --cloud-signing to let Xcode
# use a cloud-managed certificate instead).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Levels.xcodeproj"
OUT="$REPO/build/release/ios"
ARCHIVE="$OUT/Levels-iOS.xcarchive"
EXPORT="$OUT/export"

die() { echo "archive-ios: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

team="${LEVELS_TEAM_ID:-}"
build_number=""
upload=0
cloud_signing=0

while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="${2:?--team needs a Team ID}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a number}"; shift ;;
    --upload) upload=1 ;;
    --cloud-signing) cloud_signing=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- Preflight: fail before any build work -----------------------------------------------

command -v xcodebuild >/dev/null || die "xcodebuild not found; install Xcode."

if [ -z "$team" ]; then
  team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' "$REPO/Config/Levels.xcconfig" | head -1)"
fi
[ -n "$team" ] || die "no Team ID. Pass --team <TEAMID>."

if [ "$cloud_signing" -eq 0 ]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if ! grep -Eq "(Apple|iPhone) Distribution:.*\($team\)" <<<"$identities"; then
    cat >&2 <<EOF
archive-ios: no "Apple Distribution" signing identity for team $team in the keychain.

App Store builds must be signed for distribution. That needs the paid Apple Developer
Program; a free Personal Team cannot create the certificate or upload to App Store Connect.
After enrolling:
  1. Xcode > Settings > Accounts > (team) > Manage Certificates > + > Apple Distribution
     (or rerun with --cloud-signing to let Xcode use a cloud-managed certificate).
  2. Set DEVELOPMENT_TEAM in Config/Levels.xcconfig to the paid team, or pass --team.
  3. Create the app record in App Store Connect for bundle ID com.<rdns>.levels.
EOF
    exit 1
  fi
fi

auth=()
if [ -n "${LEVELS_ASC_KEY_PATH:-}" ]; then
  [ -f "$LEVELS_ASC_KEY_PATH" ] || die "LEVELS_ASC_KEY_PATH does not exist: $LEVELS_ASC_KEY_PATH"
  [ -n "${LEVELS_ASC_KEY_ID:-}" ] && [ -n "${LEVELS_ASC_ISSUER_ID:-}" ] \
    || die "set LEVELS_ASC_KEY_ID and LEVELS_ASC_ISSUER_ID with LEVELS_ASC_KEY_PATH"
  auth=(-authenticationKeyPath "$LEVELS_ASC_KEY_PATH"
        -authenticationKeyID "$LEVELS_ASC_KEY_ID"
        -authenticationKeyIssuerID "$LEVELS_ASC_ISSUER_ID")
fi

# --- Archive ----------------------------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"

overrides=(DEVELOPMENT_TEAM="$team")
[ -n "$build_number" ] && overrides+=(CURRENT_PROJECT_VERSION="$build_number")

echo "Archiving Levels-iOS (Release)..."
xcodebuild archive \
  -project "$PROJECT" -scheme Levels-iOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  "${overrides[@]}" \
  > "$OUT/archive.log" 2>&1 \
  || { tail -n 40 "$OUT/archive.log" >&2; die "archive failed (full log: $OUT/archive.log)"; }

APP="$ARCHIVE/Products/Applications/Levels.app"
[ -d "$APP" ] || die "archive has no Levels.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
echo "Levels $version ($build)"

# App Store Connect rejects an extension whose versions differ from the app's.
for appex in "$APP"/PlugIns/*.appex; do
  [ -e "$appex" ] || continue
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$appex/Info.plist")"
  b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$appex/Info.plist")"
  [ "$v" = "$version" ] && [ "$b" = "$build" ] \
    || die "$(basename "$appex") is $v ($b), the app is $version ($build); keep versions in Config/Levels.xcconfig only"
  [ -f "$appex/PrivacyInfo.xcprivacy" ] || die "$(basename "$appex") has no PrivacyInfo.xcprivacy"
done
[ -f "$APP/PrivacyInfo.xcprivacy" ] || die "Levels.app has no PrivacyInfo.xcprivacy"

# --- Export -----------------------------------------------------------------------------

destination=export
[ "$upload" -eq 1 ] && destination=upload

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

echo "Exporting for App Store Connect ($destination)..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  > "$OUT/export.log" 2>&1 \
  || { tail -n 40 "$OUT/export.log" >&2; die "export failed (full log: $OUT/export.log)"; }

if [ "$upload" -eq 1 ]; then
  echo "Uploaded Levels $version ($build) to App Store Connect. It appears in TestFlight after processing."
else
  echo "Done: $EXPORT/Levels.ipa (Levels $version ($build)). Upload with Xcode Organizer or Transporter, or rerun with --upload."
fi
