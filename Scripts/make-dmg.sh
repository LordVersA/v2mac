#!/bin/bash
# Builds a Release app, signs it (helper first, then the app) and packages a DMG.
#
#   Scripts/make-dmg.sh                     ad-hoc signed DMG in ./dist
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=my-profile Scripts/make-dmg.sh
#                                           Developer ID signing + notarization
#
# Parameters (environment): SIGN_IDENTITY (default "-", ad-hoc), NOTARY_PROFILE
# (a `notarytool store-credentials` profile; skipped when empty), OUT_DIR (default dist).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
BUILD_DIR="$ROOT/build"
ENTITLEMENTS="$ROOT/App/Resources/v2mac.entitlements"

cd "$ROOT"
[[ -x Vendor/core/xray ]] || Scripts/fetch-core.sh
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$BUILD_DIR"
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build | tail -n 3

APP="$BUILD_DIR/Build/Products/Release/V2Mac.app"
[[ -d "$APP" ]] || { echo "error: build produced no app" >&2; exit 1; }

# The helper must be signed before the app that contains it.
CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && CODESIGN_ARGS+=(--options runtime --timestamp)
/usr/bin/codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/Helpers/xray"
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/V2Mac-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The window's background and icon positions, made once by Scripts/make-dmg-layout.sh. The
# layout finds its picture by volume name and path, so neither may change here.
mkdir "$STAGE/.background"
cp "$ROOT/Scripts/dmg/background.tiff" "$STAGE/.background/background.tiff"
cp "$ROOT/Scripts/dmg/DS_Store" "$STAGE/.DS_Store"
rm -f "$DMG"
hdiutil create -quiet -volname "V2Mac" -srcfolder "$STAGE" -format UDZO -ov "$DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
echo "Built $DMG"
