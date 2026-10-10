#!/bin/bash
# Regenerates the DMG window layout kept in Scripts/dmg/: the background picture and the
# .DS_Store that places the icons on it. Run it after changing docs/images/dmg-background-source.jpg
# or the numbers below, and commit the two files. Scripts/make-dmg.sh only copies them, so a
# release build (also in CI) never has to script Finder.
#
# Do not hide the path bar here: that switch is the user's own Finder setting, not the window's.
#
# The .DS_Store is written by Finder itself, so this needs a desktop session and, the first
# time, permission for the terminal to control Finder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/docs/images/dmg-background-source.jpg"
OUT="$ROOT/Scripts/dmg"
VOLUME="V2Mac"   # must match -volname in make-dmg.sh: the layout finds its picture by this name

# Window content size in points; the picture is made at 1x and 2x.
WIDTH=660
HEIGHT=400
TITLE_BAR=28
ICON_SIZE=128
APP_X=130
APPS_X=530
# The arrow in the picture is at half height (200). Finder draws a 128-point icon with its
# centre 45 points below the position it is given, hence 155.
ICON_Y=155
# Hidden items show up for people who have hidden files turned on: park them below the window.
HIDDEN_Y=$(( HEIGHT + 300 ))

[[ -d "/Volumes/$VOLUME" ]] && { echo "error: /Volumes/$VOLUME is mounted; eject it first" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Centre-crop the source to the window's shape, then scale.
SRC_W=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')
SRC_H=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')
CROP_W=$(( SRC_H * WIDTH / HEIGHT ))
CROP_H=$SRC_H
if (( CROP_W > SRC_W )); then CROP_W=$SRC_W; CROP_H=$(( SRC_W * HEIGHT / WIDTH )); fi
sips -c "$CROP_H" "$CROP_W" "$SOURCE" -s format png --out "$WORK/crop.png" >/dev/null
sips -z "$HEIGHT" "$WIDTH" "$WORK/crop.png" --out "$WORK/background.png" >/dev/null
sips -z $(( HEIGHT * 2 )) $(( WIDTH * 2 )) "$WORK/crop.png" --out "$WORK/background@2x.png" >/dev/null
mkdir -p "$OUT"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$OUT/background.tiff" >/dev/null 2>&1

# A throwaway writable disk with the same names as the real one.
mkdir -p "$WORK/stage/V2Mac.app" "$WORK/stage/.background"
ln -s /Applications "$WORK/stage/Applications"
cp "$OUT/background.tiff" "$WORK/stage/.background/background.tiff"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -size 20m "$WORK/layout.dmg"
hdiutil attach "$WORK/layout.dmg" -quiet -noautoopen

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 13
    -- Finder picks black or white icon names from this colour, also under a picture.
    set background color of opts to {2000, 3000, 6000}
    set background picture of opts to file ".background:background.tiff"
    delay 1
    -- Last, and once the window has settled: Finder moves the icons when the toolbar goes.
    set the bounds of container window to {200, 120, $(( 200 + WIDTH )), $(( 120 + HEIGHT + TITLE_BAR ))}
    set position of item "V2Mac.app" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
    try
      set position of item ".background" of container window to {$APP_X, $HIDDEN_Y}
    end try
    try
      set position of item ".fseventsd" of container window to {$APPS_X, $HIDDEN_Y}
    end try
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Finder writes the window's own settings when the disk goes away, so read the file after a remount.
sync
hdiutil detach "/Volumes/$VOLUME" -quiet
hdiutil attach "$WORK/layout.dmg" -quiet -noautoopen
cp "/Volumes/$VOLUME/.DS_Store" "$OUT/DS_Store"
hdiutil detach "/Volumes/$VOLUME" -quiet
ls -la "$OUT"
