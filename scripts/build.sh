#!/bin/bash
# Generates the Xcode project and builds xFinder.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
xcodegen generate --quiet
set +e
xcodebuild -project xFinder.xcodeproj -scheme xFinder -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData build > build/xcodebuild.log 2>&1
STATUS=$?
set -e
grep -E "^/[^ ]+:[0-9]+:[0-9]+: (error|warning): " build/xcodebuild.log | grep -v "/.build/\|/SourcePackages/\|/Vendor/" | sort -u | head -80 || true
grep -E "\*\* BUILD" build/xcodebuild.log || tail -5 build/xcodebuild.log
echo "App: build/DerivedData/Build/Products/$CONFIG/xFinder.app"
exit $STATUS
