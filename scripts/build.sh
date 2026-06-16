#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DISPLAY_NAME="不要久坐"
EXECUTABLE_NAME="PostureBreakReminder"
APP="$ROOT/build/$APP_DISPLAY_NAME.app"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"

rm -rf "$APP" "$ROOT/build/PostureBreakReminder.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/config/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ImageIO \
  -framework Vision \
  -o "$EXECUTABLE" \
  "$ROOT/Sources/main.swift"

chmod +x "$EXECUTABLE"
codesign --force --deep --sign - "$APP" >/dev/null

echo "$APP"
