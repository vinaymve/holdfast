#!/bin/bash
# Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE). Derived from SelfControl.
# Packages build/Holdfast.app into build/Holdfast-<version>.dmg with an Applications shortcut.
# Run Scripts/build-app.sh first. If CODESIGN_IDENTITY is set the disk image is signed too.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Holdfast.app"
[ -d "$APP" ] || { echo "Run Scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Holdfast-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Holdfast" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG"
