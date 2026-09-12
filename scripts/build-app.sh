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

# Ad-hoc sign for local development so macOS sees a stable app bundle.
codesign --force --deep --sign - "$APP"

echo
echo "Built: $APP"
echo "Opening NUKE.app…"
open "$APP"
