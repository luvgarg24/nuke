#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building NUKE…"
swift build -c release

APP="$PWD/dist/NUKE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PWD/.build/release/NUKE" "$APP/Contents/MacOS/NUKE"
cp "$PWD/App/Info.plist" "$APP/Contents/Info.plist"
cp "$PWD/assets/nuke-logo.svg" "$APP/Contents/Resources/nuke-logo.svg"

# Render the vector logo into a native macOS .icns during local builds.
ICON_TMP="$PWD/.build/nuke-icon"
ICONSET="$ICON_TMP/NUKE.iconset"
rm -rf "$ICON_TMP"
mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o "$ICON_TMP" "$PWD/assets/nuke-logo.svg" >/dev/null 2>&1
RENDERED="$ICON_TMP/nuke-logo.svg.png"
if [ -f "$RENDERED" ]; then
  sips -z 16 16 "$RENDERED" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$RENDERED" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$RENDERED" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$RENDERED" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$RENDERED" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$RENDERED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$RENDERED" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$RENDERED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$RENDERED" --out "$ICONSET/icon_512x512.png" >/dev/null
  cp "$RENDERED" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/NUKE.icns"
  touch "$APP"
else
  echo "ERROR: couldn't render NUKE icon."
  exit 1
fi
rm -rf "$ICON_TMP"

# Ad-hoc sign after every resource has been installed.
codesign --force --deep --sign - "$APP"

# Register this exact bundle with Launch Services before opening it. This avoids
# macOS keeping the generic executable icon for a freshly-built local app.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo
echo "Built: $APP"
echo "Opening NUKE.app…"
open "$APP"
