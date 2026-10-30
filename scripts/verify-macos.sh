#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null || ! command -v swift >/dev/null; then
    echo "Install Xcode and select it with xcode-select before running these checks." >&2
    exit 1
fi
swift test
xcodebuild -project NIBMOne.xcodeproj -scheme NIBMOne \
    -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
echo "Domain tests and simulator build passed. Complete the device checklist in FEATURE_AUDIT.md."
