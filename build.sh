#!/bin/bash
# Builds CueDeck.app into ./build. Requires the Xcode Command Line Tools
# (xcode-select --install) on macOS 13 or newer.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not found. Install the Command Line Tools first: xcode-select --install" >&2
    exit 1
fi

CONFIG="${1:-release}"
echo "Building CueDeck ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/CueDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CueDeck" "$APP/Contents/MacOS/CueDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon: built with Apple's iconutil from the 1024 px master so every size
# (including the small Finder list icons) is encoded the way macOS expects.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
ICON_OK=1
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || ICON_OK=0
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || ICON_OK=0
done
if [ "$ICON_OK" = 1 ] && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    :
else
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so it runs on Apple Silicon. Use a Developer ID to distribute.
codesign --force --sign - "$APP" >/dev/null

# Register with Launch Services so Finder offers CueDeck under "Open With"
# and shows the new icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo ""
echo "Done: $(pwd)/$APP"
echo "Start it with:  open \"$APP\"   (or drag it into /Applications)"
