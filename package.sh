#!/bin/bash
# Builds a universal CueDeck.app (Apple Silicon + Intel) and packs it into
# build/CueDeck-<version>.dmg for installing on other Macs.
# The app is signed ad hoc (no Developer ID), so macOS asks once before the
# first launch on another Mac; see README "Installing on another Mac".
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

# Intel slice, built separately (a one-step universal build needs full Xcode).
echo "Building the Intel version…"
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build-x86
ARM="$(swift build -c release --show-bin-path)/CueDeck"
X86=".build-x86/x86_64-apple-macosx/release/CueDeck"

APP="build/CueDeck.app"
lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/CueDeck"
codesign --force --sign - "$APP" >/dev/null
lipo -info "$APP/Contents/MacOS/CueDeck"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/CueDeck-$VERSION.dmg"
STAGE="$(mktemp -d)/CueDeck"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp install.sh "$STAGE/install.sh"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "CueDeck $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "Done: $(pwd)/$DMG"
