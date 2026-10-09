#!/bin/bash
# Xcode build phase: copies the vendored core into the app bundle.
set -euo pipefail
SRC="$SRCROOT/Vendor/core"
if [[ ! -x "$SRC/xray" ]]; then
  echo "error: Vendor/core/xray missing. Run Scripts/fetch-core.sh" >&2
  exit 1
fi
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$HELPERS" "$RES"
cp -f "$SRC/xray" "$HELPERS/xray"
cp -f "$SRC/geoip.dat" "$SRC/geosite.dat" "$RES/"
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPERS/xray"
else
  /usr/bin/codesign --force --sign - "$HELPERS/xray"
fi
