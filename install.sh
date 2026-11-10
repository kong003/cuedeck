#!/bin/sh
# Installs or updates CueDeck in /Applications (or ~/Applications) and allows it to run.
#
#   sh "/Volumes/CueDeck 0.7.1/install.sh"     (from the opened DMG)
#   sh install.sh ~/Downloads/CueDeck-0.7.1.dmg
#   sh install.sh                              (newest CueDeck-*.dmg in Downloads)
#
# CueDeck has no Developer ID signature, so macOS blocks a copied app until
# the quarantine flag is removed; this script does that for you.
# Accounts without admin rights get CueDeck in ~/Applications instead.
set -eu

APP="CueDeck.app"
# /Applications if this account may write there (directly or as an admin with
# sudo). Other accounts can name an admin account to install there with its
# password (no need to log out), or get CueDeck in their own ~/Applications.
ADMIN=""
if [ -w /Applications ] || id -Gn | grep -qw admin; then
    APPS="/Applications"
else
    APPS="$HOME/Applications"
    if [ -t 0 ]; then
        echo "This account has no administrator rights."
        printf "Name of an admin account to install for all users (Return = only for you): "
        read -r ADMIN
        if [ -n "$ADMIN" ]; then APPS="/Applications"; fi
    fi
fi
DEST="$APPS/$APP"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOUNT=""

cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet || true; fi
}
trap cleanup EXIT

# Where the new app comes from: next to this script (inside the DMG) or a DMG.
if [ -d "$HERE/$APP" ]; then
    SRC="$HERE/$APP"
else
    DMG="${1:-}"
    if [ -z "$DMG" ]; then
        DMG="$(ls -t "$HOME"/Downloads/CueDeck-*.dmg "$HERE"/CueDeck-*.dmg 2>/dev/null | head -n 1 || true)"
    fi
    if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
        echo "No CueDeck DMG found."
        echo "Usage: sh install.sh path/to/CueDeck-x.y.z.dmg"
        exit 1
    fi
    echo "Opening $DMG"
    MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | tail -n 1 | awk -F'\t' '{print $NF}')"
    SRC="$MOUNT/$APP"
fi

if [ ! -d "$SRC" ]; then
    echo "$APP not found in $(dirname "$SRC")."
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "Installing CueDeck $VERSION"

# Quit a running CueDeck normally, so it saves the cue list first.
if pgrep -x CueDeck >/dev/null 2>&1; then
    echo "Quitting CueDeck…"
    osascript -e 'quit app "CueDeck"' >/dev/null 2>&1 || true
    i=0
    while pgrep -x CueDeck >/dev/null 2>&1 && [ $i -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    if pgrep -x CueDeck >/dev/null 2>&1; then
        echo "CueDeck is still running. Quit it and run this script again."
        exit 1
    fi
fi

# Replace the app (an admin account without write access needs sudo).
if [ -n "$ADMIN" ]; then
    echo "Enter the password of $ADMIN (it may be asked twice)."
    su "$ADMIN" -c "sudo rm -rf '$DEST' && sudo ditto '$SRC' '$DEST' && sudo xattr -dr com.apple.quarantine '$DEST'"
elif mkdir -p "$APPS" 2>/dev/null && [ -w "$APPS" ]; then
    rm -rf "$DEST"
    ditto "$SRC" "$DEST"
else
    echo "Administrator password needed to write to $APPS."
    sudo rm -rf "$DEST"
    sudo ditto "$SRC" "$DEST"
    sudo chown -R "$(id -un)" "$DEST"
fi

# Allow it to run (removes the "downloaded from the internet" flag).
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if [ "$APPS" != "/Applications" ] && [ -d "/Applications/$APP" ]; then
    echo "Note: an older CueDeck is still in /Applications. Only an administrator can remove it."
fi
echo "CueDeck $VERSION is installed in $APPS. Starting it…"
open "$DEST"
