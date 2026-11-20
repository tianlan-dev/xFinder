#!/bin/bash
# Builds xFinderKit with SwiftPM and prints only errors and xFinderKit warnings.
cd "$(dirname "$0")/.."
swift build "$@" > build/swiftbuild.log 2>&1
STATUS=$?
grep -E "^/.*(error|warning): " build/swiftbuild.log | grep -v "/Vendor/\|/.build/" | sort -u | head -60
grep -E "error: " build/swiftbuild.log | grep -v "^/" | head -5
[ $STATUS -eq 0 ] && echo "KIT BUILD OK" || echo "KIT BUILD FAILED"
exit $STATUS
