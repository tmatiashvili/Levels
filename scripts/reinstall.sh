#!/bin/bash
# Rebuild and reinstall the Levels apps on this Mac and the iPhone.
#
# The free Personal Team profile lasts 7 days, so run this once a week:
#
#   scripts/reinstall.sh               # Mac and iPhone
#   scripts/reinstall.sh --mac-only
#   scripts/reinstall.sh --ios-only
#   scripts/reinstall.sh --device <UDID>   # or LEVELS_IPHONE_ID=<UDID>
#
# Mac: builds Levels-Mac (Debug), quits Levels, replaces
# ~/Desktop/Levels-try/Levels.app (override with LEVELS_MAC_APP), re-registers
# the app and its widget, and opens it again.
# iPhone: builds Levels-iOS (Debug) for the device and installs it with
# devicectl. With no reachable iPhone it says so and skips it.
# Build output goes to build/ in the repo (gitignored).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Levels.xcodeproj"
DERIVED="$REPO/build/DerivedData"
MAC_APP="${LEVELS_MAC_APP:-$HOME/Desktop/Levels-try/Levels.app}"
DEFAULT_IPHONE="00008160-00182C110491400A"
BUNDLE_ID="com.tmatiashvili.levels"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

do_mac=1
do_ios=1
device="${LEVELS_IPHONE_ID:-}"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mac-only) do_ios=0 ;;
    --ios-only) do_mac=0 ;;
    --device) device="${2:?--device needs a UDID}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ "$do_mac" = 0 ] && [ "$do_ios" = 0 ]; then
  echo "--mac-only and --ios-only together build nothing." >&2
  exit 2
fi

say() { printf '==> %s\n' "$*"; }

LOG_DIR="$REPO/build/logs"
mkdir -p "$LOG_DIR"

# Runs xcodebuild quietly; on failure shows the errors and the log path.
build() {
  local name="$1"; shift
  local logfile="$LOG_DIR/$name.log"
  if ! xcodebuild -project "$PROJECT" -configuration Debug \
      -derivedDataPath "$DERIVED" -allowProvisioningUpdates "$@" build \
      >"$logfile" 2>&1; then
    grep -E 'error:|BUILD FAILED' "$logfile" | head -20 >&2 || true
    echo "Build of $name failed. Full log: $logfile" >&2
    return 1
  fi
}

# Prints the ExpirationDate of a profile file, or nothing.
profile_expiry() {
  local file="$1"
  [ -f "$file" ] || return 0
  security cms -D -i "$file" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true
}

# Earliest expiry among the profiles inside an app bundle (app + widget).
earliest_expiry() {
  local app="$1"
  find "$app" \( -name embedded.provisionprofile -o -name embedded.mobileprovision \) -print0 \
    | while IFS= read -r -d '' f; do profile_expiry "$f"; echo; done \
    | grep . | sort | head -1 || true
}

# Shows an ISO date like 2026-12-01T10:00:00Z in local time.
local_date() {
  local epoch
  if epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null)"; then
    date -r "$epoch" '+%a %d %b %Y, %H:%M %Z'
  else
    echo "$1"
  fi
}

# A reachable physical iPhone: the given one if it is available, else the
# only available one, else the default if available.
find_iphone() {
  local list
  list="$(xcrun devicectl list devices 2>/dev/null \
    | grep -E 'physical' | grep -E 'iPhone' | grep -E 'available' || true)"
  if [ -n "$device" ]; then
    grep -q -- "$device" <<<"$list" && echo "$device"
    return 0
  fi
  local ids
  ids="$(grep -oE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' <<<"$list" || true)"
  if [ "$(grep -c . <<<"$ids" || true)" = 1 ]; then
    echo "$ids"
  elif grep -q -- "$DEFAULT_IPHONE" <<<"$list"; then
    echo "$DEFAULT_IPHONE"
  fi
}

mac_expiry=""
ios_expiry=""
ios_status="not built"

if [ "$do_mac" = 1 ]; then
  say "Mac: building Levels-Mac (Debug)…"
  build Levels-Mac -scheme Levels-Mac -destination 'platform=macOS'
  built="$DERIVED/Build/Products/Debug/Levels.app"
  [ -d "$built" ] || { echo "Built app not found at $built" >&2; exit 1; }

  say "Mac: quitting Levels…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -f "$MAC_APP/Contents/MacOS/Levels" >/dev/null || break
    sleep 1
  done
  pkill -f "$MAC_APP/Contents/MacOS/Levels" 2>/dev/null || true
  pkill -f "$MAC_APP/Contents/PlugIns/" 2>/dev/null || true

  say "Mac: replacing ${MAC_APP}…"
  mkdir -p "$(dirname "$MAC_APP")"
  rm -rf "$MAC_APP"
  ditto "$built" "$MAC_APP"

  # Only the installed copy should be known to the system, so the widget
  # runs from it and not from the build folder.
  "$LSREGISTER" -u "$built" >/dev/null 2>&1 || true
  pluginkit -r "$built/Contents/PlugIns/LevelsWidgets.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$MAC_APP" >/dev/null 2>&1 || true
  pluginkit -a "$MAC_APP/Contents/PlugIns/LevelsWidgets.appex" >/dev/null 2>&1 || true

  say "Mac: opening Levels…"
  open "$MAC_APP"
  mac_expiry="$(earliest_expiry "$MAC_APP")"
  say "Mac: done."
fi

if [ "$do_ios" = 1 ]; then
  say "iPhone: looking for a connected iPhone…"
  udid="$(find_iphone)"
  if [ -z "$udid" ]; then
    if [ -n "$device" ]; then
      say "iPhone: $device is not reachable (connect it or join the same Wi-Fi). Skipping the iPhone."
    else
      say "iPhone: none reachable (connect it or join the same Wi-Fi). Skipping the iPhone."
    fi
    ios_status="skipped"
  else
    say "iPhone: building Levels-iOS (Debug) for ${udid}…"
    build Levels-iOS -scheme Levels-iOS -destination "id=$udid" \
      -allowProvisioningDeviceRegistration
    ios_app="$DERIVED/Build/Products/Debug-iphoneos/Levels.app"
    [ -d "$ios_app" ] || { echo "Built app not found at $ios_app" >&2; exit 1; }

    say "iPhone: installing…"
    xcrun devicectl device install app --device "$udid" "$ios_app" \
      >"$LOG_DIR/ios-install.log" 2>&1 \
      || { tail -20 "$LOG_DIR/ios-install.log" >&2; exit 1; }
    ios_expiry="$(earliest_expiry "$ios_app")"
    ios_status="installed"

    say "iPhone: opening Levels…"
    if ! xcrun devicectl device process launch --device "$udid" "$BUNDLE_ID" \
        >"$LOG_DIR/ios-launch.log" 2>&1; then
      say "iPhone: installed, but could not open it (unlock the iPhone, or trust the developer in Settings > General > VPN & Device Management)."
    fi
    say "iPhone: done."
  fi
fi

echo
[ "$do_mac" = 1 ] && echo "Mac app:    installed at $MAC_APP${mac_expiry:+, profile expires $(local_date "$mac_expiry")}"
[ "$do_ios" = 1 ] && echo "iPhone app: $ios_status${ios_expiry:+, profile expires $(local_date "$ios_expiry")}"

next="$(printf '%s\n%s\n' "$mac_expiry" "$ios_expiry" | grep . | sort | head -1 || true)"
if [ -n "$next" ]; then
  echo "Run this again before $(local_date "$next")."
fi
