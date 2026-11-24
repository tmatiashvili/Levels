#!/bin/sh
# Compile Levels-Mac/AppIcon.icon with actool and render a preview sheet
# (1024, 32 and 16 px, plus light, dark and clear looks) to the given PNG.
# Usage: design/icon/preview.sh <out.png>
set -eu
out=${1:?usage: preview.sh <out.png>}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app="$work/LevelsIconPreview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun actool "$root/Levels-Mac/AppIcon.icon" --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$work/partial.plist" >/dev/null
# A bundle with no executable gets the "can't open" badge, so give it one.
cp /usr/bin/true "$app/Contents/MacOS/LevelsIconPreview"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>levels.icon-preview.$$</string>
<key>CFBundleExecutable</key><string>LevelsIconPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
</dict></plist>
EOF

xcrun clang -fobjc-arc -framework AppKit "$here/preview.m" -o "$work/preview"
"$work/preview" "$app" "$out"
echo "wrote $out"
