#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/build.sh")"
DIST="$ROOT/dist"
DMG="$DIST/不要久坐.dmg"
STAGING="$ROOT/build/dmg-staging"

mkdir -p "$DIST"
rm -f "$DMG"
rm -f "$DIST/PostureBreakReminder.dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING"
SetFile -a V "$STAGING/.VolumeIcon.icns"

hdiutil create \
  -volname "不要久坐" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

echo "$DMG"
