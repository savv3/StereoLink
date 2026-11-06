#!/bin/bash
# Builds the StereoLink virtual audio device into build/StereoLink.driver (universal).
# Set SIGN_IDENTITY to a real identity; defaults to ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

DRIVER="build/StereoLink.driver"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"

clang -bundle -O2 -std=c11 -Wall -Wextra \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRIVER/Contents/MacOS/StereoLinkDriver" Driver/StereoLinkDriver.c

codesign --force --sign "${SIGN_IDENTITY:--}" "$DRIVER"
echo "Built $DRIVER"
