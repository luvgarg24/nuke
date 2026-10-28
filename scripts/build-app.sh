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

# Icon packaging must never block a valid application build.
# If the source asset cannot be decoded on this Mac, NUKE still gets bundled,
# signed, registered and opened with the freshly compiled executable.
ICON_TMP="$PWD/.build/nuke-icon"
ICONSET="$ICON_TMP/NUKE.iconset"
SOURCE="$PWD/assets/nuke-logo.png"
rm -rf "$ICON_TMP"
mkdir -p "$ICONSET"

ICON_BUILT=false
if [ -s "$SOURCE" ]; then
  if sips -z 16 16 "$SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1 \
    && sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1 \
    && sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1 \
    && sips -z 64 64 "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1 \
    && sips -z 128 128 "$SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1 \
    && sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1 \
    && sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1 \
    && sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1 \
    && sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1 \
    && sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1 \
    && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/NUKE.icns" >/dev/null 2>&1; then
      ICON_BUILT=true
  fi
fi

if [ "$ICON_BUILT" = false ]; then
  echo "Warning: icon packaging skipped; continuing with the app build."
fi

rm -rf "$ICON_TMP"
touch "$APP"
codesign --force --deep --sign - "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo
echo "Built: $APP"
echo "Opening NUKE.app…"
open "$APP"
