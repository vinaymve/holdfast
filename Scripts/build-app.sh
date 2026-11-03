#!/bin/bash
# Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE). Derived from SelfControl.
# Builds build/Holdfast.app (ad-hoc signed) containing the app, the privileged helper, and the CLI.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Holdfast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Holdfast"     "$APP/Contents/MacOS/Holdfast"
cp "$BIN/holdfastd"    "$APP/Contents/MacOS/holdfastd"
cp "$BIN/holdfast-cli" "$APP/Contents/MacOS/holdfast-cli"
cp Resources/Holdfast.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Holdfast</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>dev.holdfast.app</string>
    <key>CFBundleName</key><string>Holdfast</string>
    <key>CFBundleDisplayName</key><string>Holdfast</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later. Derived from SelfControl by Charlie Stigler et al.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Signing. Default is an ad-hoc signature, enough to run locally.
# For a public release set CODESIGN_IDENTITY to a "Developer ID Application: ..." identity. The helper, CLI and app
# are then signed individually (no --deep) with the hardened runtime and a secure timestamp, and the installer pins
# the helper to the app's Team ID. Notarize afterwards:  xcrun notarytool submit ... && xcrun stapler staple "$APP"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  for exe in holdfastd holdfast-cli; do
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/$exe"
  done
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP/Contents/MacOS/holdfastd" "$APP/Contents/MacOS/holdfast-cli"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
