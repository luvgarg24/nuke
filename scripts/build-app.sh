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

# Render the SVG itself instead of a Quick Look thumbnail. qlmanage thumbnails
# wrap SVG documents in a white preview card, which becomes part of the app icon.
ICON_TMP="$PWD/.build/nuke-icon"
ICONSET="$ICON_TMP/NUKE.iconset"
RENDERED="$ICON_TMP/nuke-logo.png"
rm -rf "$ICON_TMP"
mkdir -p "$ICON_TMP" "$ICONSET"

if ! sips -s format png "$PWD/assets/nuke-logo.svg" --out "$RENDERED" >/dev/null 2>&1; then
  echo "ERROR: macOS could not render assets/nuke-logo.svg into a PNG."
  exit 1
fi

if [ ! -s "$RENDERED" ]; then
  echo "ERROR: rendered NUKE logo is missing."
  exit 1
fi

sips -z 16 16 "$RENDERED" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$RENDERED" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$RENDERED" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$RENDERED" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$RENDERED" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$RENDERED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$RENDERED" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$RENDERED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$RENDERED" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$RENDERED" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/NUKE.icns"

if [ ! -s "$APP/Contents/Resources/NUKE.icns" ]; then
  echo "ERROR: NUKE.icns was not created."
  exit 1
fi

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$ICON_NAME" != "NUKE.icns" ]; then
  echo "ERROR: built Info.plist does not contain CFBundleIconFile=NUKE.icns."
  exit 1
fi

rm -rf "$ICON_TMP"
touch "$APP"
codesign --force --deep --sign - "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch "$APP"
killall Dock >/dev/null 2>&1 || true

echo "Icon: $(ls -lh "$APP/Contents/Resources/NUKE.icns" | awk '{print $5}') NUKE.icns"
echo
echo "Built: $APP"
echo "Opening NUKE.app…"
open "$APP"
