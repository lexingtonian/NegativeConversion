#!/bin/bash
# Copies the optimised release build, signs it locally (ad hoc) with the App
# Store entitlements, so it runs in the sandbox, and opens it. No Xcode involved.
set -e
cd "$(dirname "$0")"
SRC=".build/xcode/Build/Products/Release/Negative Conversion.app"
DST=".build/sandboxed/Negative Conversion.app"
rm -rf "$DST"; mkdir -p "$(dirname "$DST")"; cp -R "$SRC" "$DST"
codesign --force --sign - --options runtime --entitlements NegativeConverter.entitlements "$DST"
codesign -d --entitlements - "$DST" 2>/dev/null | grep -o "app-sandbox" && echo "signed with sandbox"
open "$DST"
