#!/bin/bash
#
# Compile everything without needing a signing identity.
#
# This is the first thing to run on a Mac. It builds both targets for the
# simulator with signing switched off, which is enough to surface every
# compile error in the project — and since none of this code has ever been
# through a compiler, expect some.
#
# A device build needs signing; see the notes at the bottom.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store, then:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

echo "==> $(xcodebuild -version | head -1)"
echo "==> Building Dictation (app + keyboard extension) for the simulator"
echo

# CODE_SIGNING_ALLOWED=NO is what lets this run before a team is configured.
# The extension is built as a dependency of the app, so both get compiled.
xcodebuild \
    -project Dictation.xcodeproj \
    -scheme Dictation \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO \
    build \
    "$@"

echo
echo "==> Compiled."
echo
echo "Next, to run on a device:"
echo "  1. Open Dictation.xcodeproj and set your team on BOTH targets"
echo "     (Signing & Capabilities → Team), or pass it here:"
echo "       scripts/build-check.sh DEVELOPMENT_TEAM=XXXXXXXXXX"
echo "  2. Confirm the App Group group.com.asre1212.dictation is present on"
echo "     both targets. The app's Settings screen reports whether it works."
echo "  3. Run the app, allow the microphone, then add the keyboard in"
echo "     Settings › General › Keyboard and turn on Allow Full Access."
