#!/bin/bash
# Builds an ad-hoc signed Release of xFinder and packages it for GitHub Releases.
# Usage: scripts/package_release.sh <version> [build-number]
# Output: dist/xFinder-<version>.zip, dist/xFinder-<version>.dmg, dist/SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: package_release.sh <version> [build-number]}"
VERSION="${VERSION#v}"
BUILD="${2:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }

xcodegen generate --quiet
rm -rf build/release dist
mkdir -p build dist
set +e
xcodebuild -project xFinder.xcodeproj -scheme xFinder -configuration Release \
  -derivedDataPath build/release \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build > build/release.log 2>&1
STATUS=$?
set -e
if [ $STATUS -ne 0 ]; then
  grep -E "error:" build/release.log | sort -u | head -50 || true
  tail -30 build/release.log
  exit $STATUS
fi

APP="build/release/Build/Products/Release/xFinder.app"
FOUND=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$FOUND" = "$VERSION" ] || { echo "Built version $FOUND does not match $VERSION" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|flags" || true

ZIP="dist/xFinder-$VERSION.zip"
DMG="dist/xFinder-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/xFinder.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "xFinder $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

(cd dist && shasum -a 256 "xFinder-$VERSION.zip" "xFinder-$VERSION.dmg" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
