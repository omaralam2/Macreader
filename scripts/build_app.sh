#!/bin/bash
# Builds build/MacReader.app from the Swift package. Run on macOS 13+ with Xcode
# or the Command Line Tools installed (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/MacReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacReader" "$APP/Contents/MacOS/MacReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature by default so macOS will run it locally. An ad-hoc identity
# changes on every build, so macOS forgets Full Disk Access after a rebuild.
# To keep the permission, sign with a real certificate:
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build_app.sh
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"

echo
echo "✅ Built $APP"
echo "   Run it with:  open \"$APP\""
echo "   Or install:   cp -R \"$APP\" /Applications/"
