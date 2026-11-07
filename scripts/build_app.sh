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

# Ad-hoc signature so macOS will run it locally.
codesign --force --deep --sign - "$APP"

echo
echo "✅ Built $APP"
echo "   Run it with:  open \"$APP\""
echo "   Or install:   cp -R \"$APP\" /Applications/"
