#!/bin/bash
# Builds and tests the package and writes everything to check.log,
# so the result can be read without copying anything from Terminal.
cd "$(dirname "$0")"
{
  echo "== $(date)"; sw_vers; swift --version; xcodebuild -version
  echo "== swift build"; swift build 2>&1; echo "exit $?"
  echo "== swift test";  swift test 2>&1;  echo "exit $?"
  echo "== signing identities"; security find-identity -v -p codesigning
  echo "== xcodegen"; xcodegen generate 2>&1; echo "exit $?"
  echo "== xcodebuild (Release, universal, unsigned)"
  xcodebuild -project NegativeConverter.xcodeproj -scheme NegativeConverter \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build 2>&1 \
    | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
  APP=".build/xcode/Build/Products/Release/Negative Conversion.app"
  [ -d "$APP" ] && { lipo -archs "$APP/Contents/MacOS/Negative Conversion"; plutil -p "$APP/Contents/Info.plist"; }
} > check.log 2>&1
tail -3 check.log
