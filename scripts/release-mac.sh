#!/bin/bash
# Build a notarized Levels for Mac for direct download (Developer ID).
#
#   scripts/release-mac.sh --notary-profile <name> [--team <TEAMID>] [--build-number <N>] [--no-dmg]
#
#   --notary-profile  keychain profile for `xcrun notarytool` (or LEVELS_NOTARY_PROFILE).
#                     Create it once:
#                       xcrun notarytool store-credentials <name> \
#                         --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#   --team            paid Apple Developer Program Team ID (or LEVELS_TEAM_ID). Default: the
#                     DEVELOPMENT_TEAM in Config/Levels.xcconfig.
#   --build-number    sets CURRENT_PROJECT_VERSION for this build (default: the xcconfig value).
#   --no-dmg          produce only the stapled zip.
#
# Steps: archive Levels-Mac (Release) -> export with Developer ID signing -> check the
# signature (Developer ID, Hardened Runtime, no get-task-allow) -> notarize the app and
# staple it -> zip -> DMG, signed, notarized and stapled -> Gatekeeper check.
# Output: build/release/mac/Levels-<version>.zip, Levels-<version>.dmg and SHA256SUMS.txt
# (gitignored). Implements REL-001 R16-R18 and ADR-0022 Decision 2.
#
# Needs the paid Apple Developer Program: a free Personal Team has no Developer ID
# certificate, so the script stops before building when none is in the keychain.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Levels.xcodeproj"
OUT="$REPO/build/release/mac"
ARCHIVE="$OUT/Levels-Mac.xcarchive"
EXPORT="$OUT/export"

die() { echo "release-mac: $*" >&2; exit 1; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

profile="${LEVELS_NOTARY_PROFILE:-}"
team="${LEVELS_TEAM_ID:-}"
build_number=""
make_dmg=1

while [ $# -gt 0 ]; do
  case "$1" in
    --notary-profile) profile="${2:?--notary-profile needs a name}"; shift ;;
    --team) team="${2:?--team needs a Team ID}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a number}"; shift ;;
    --no-dmg) make_dmg=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- Preflight: fail before any build work -----------------------------------------------

[ -n "$profile" ] || die "no notary keychain profile. Pass --notary-profile <name> (see --help)."
command -v xcodebuild >/dev/null || die "xcodebuild not found; install Xcode."
xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found; install Xcode 13 or later."
xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found; install Xcode."

if [ -z "$team" ]; then
  team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' "$REPO/Config/Levels.xcconfig" | head -1)"
fi
[ -n "$team" ] || die "no Team ID. Pass --team <TEAMID>."

identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
identity_line="$(grep -m1 "Developer ID Application:.*($team)" <<<"$identities" || true)"
if [ -z "$identity_line" ]; then
  cat >&2 <<EOF
release-mac: no "Developer ID Application" signing identity for team $team in the keychain.

Direct-download Mac builds must be signed with Developer ID and notarized. That needs
the paid Apple Developer Program; a free Personal Team cannot create the certificate.
After enrolling:
  1. Xcode > Settings > Accounts > (team) > Manage Certificates > + > Developer ID Application
  2. Set DEVELOPMENT_TEAM in Config/Levels.xcconfig to the paid team, or pass --team.
  3. xcrun notarytool store-credentials $profile --apple-id <id> --team-id <TEAMID> --password <app-specific>
EOF
  exit 1
fi
identity_name="$(sed 's/.*"\(.*\)".*/\1/' <<<"$identity_line")"
echo "Signing identity: $identity_name"

# Checks the stored credentials now rather than after a 5-minute build.
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
  || die "notarytool cannot use keychain profile '$profile'. Create it with: xcrun notarytool store-credentials $profile ..."

# --- Archive and export -----------------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"

overrides=(DEVELOPMENT_TEAM="$team")
[ -n "$build_number" ] && overrides+=(CURRENT_PROJECT_VERSION="$build_number")

echo "Archiving Levels-Mac (Release)..."
xcodebuild archive \
  -project "$PROJECT" -scheme Levels-Mac -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${overrides[@]}" \
  > "$OUT/archive.log" 2>&1 \
  || { tail -n 40 "$OUT/archive.log" >&2; die "archive failed (full log: $OUT/archive.log)"; }

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
</dict>
</plist>
EOF

echo "Exporting with Developer ID..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  > "$OUT/export.log" 2>&1 \
  || { tail -n 40 "$OUT/export.log" >&2; die "export failed (full log: $OUT/export.log)"; }

APP="$EXPORT/Levels.app"
[ -d "$APP" ] || die "export produced no Levels.app in $EXPORT"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
echo "Levels $version ($build)"

# --- Signature checks (what notarization rejects) ---------------------------------------

codesign --verify --deep --strict --verbose=2 "$APP"
for bundle in "$APP" "$APP"/Contents/PlugIns/*.appex; do
  info="$(codesign -dvv "$bundle" 2>&1)"
  entitlements="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  grep -q "Authority=Developer ID Application" <<<"$info" \
    || die "$bundle is not signed with Developer ID"
  grep -q "flags=.*runtime" <<<"$info" \
    || die "$bundle has no Hardened Runtime (ENABLE_HARDENED_RUNTIME)"
  if grep -q "get-task-allow" <<<"$entitlements"; then
    die "$bundle still has com.apple.security.get-task-allow (a Debug entitlement)"
  fi
done

# --- Notarize and staple the app --------------------------------------------------------

ZIP="$OUT/Levels-$version.zip"
ditto -c -k --keepParent "$APP" "$OUT/notarize-app.zip"
echo "Notarizing the app (this can take a few minutes)..."
xcrun notarytool submit "$OUT/notarize-app.zip" --keychain-profile "$profile" --wait
rm -f "$OUT/notarize-app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Stapled zip: $ZIP"

# --- DMG --------------------------------------------------------------------------------

if [ "$make_dmg" -eq 1 ]; then
  DMG="$OUT/Levels-$version.dmg"
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Levels.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Levels" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --sign "$identity_name" --timestamp "$DMG"
  echo "Notarizing the DMG..."
  xcrun notarytool submit "$DMG" --keychain-profile "$profile" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  echo "Stapled DMG: $DMG"
fi

spctl --assess --type execute --verbose=2 "$APP"
# REL-001 R18: the download page lists the SHA-256 of each file.
(cd "$OUT" && shasum -a 256 Levels-"$version".zip $( [ "$make_dmg" -eq 1 ] && echo Levels-"$version".dmg ) | tee SHA256SUMS.txt)
echo "Done. Levels $version ($build) is signed, notarized and stapled."
