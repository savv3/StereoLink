#!/bin/bash
# Builds StereoLink.app into ./build. Usage: scripts/build-app.sh [debug|release]
# Set SIGN_IDENTITY to a Developer ID / Apple Development identity; defaults to ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/StereoLink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/StereoLink" "$APP/Contents/MacOS/StereoLink"
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
