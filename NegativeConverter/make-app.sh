#!/bin/bash
# Builds a release binary and wraps it in a double-clickable NegativeConverter.app
# next to this script. Run on a Mac with Xcode or the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product NegativeConverter
BIN="$(swift build -c release --show-bin-path)/NegativeConverter"

APP="NegativeConverter.app"
rm -rf "./$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NegativeConverter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NegativeConverter</string>
    <key>CFBundleIdentifier</key><string>art.slowlight.negative-converter</string>
    <key>CFBundleName</key><string>Negative Conversion</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict>
</plist>
PLIST
echo "Built $(pwd)/$APP"
