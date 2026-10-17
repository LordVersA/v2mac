#!/bin/bash
# Xcode build phase: embed the daemon and its launchd registration in the signed app.
set -euo pipefail

SERVICE="$PRODUCT_BUNDLE_IDENTIFIER.privileged"
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
TOOLS="$CONTENTS/Library/HelperTools"
DAEMONS="$CONTENTS/Library/LaunchDaemons"
mkdir -p "$TOOLS" "$DAEMONS"
cp -f "$BUILT_PRODUCTS_DIR/V2MacPrivilegedHelper" "$TOOLS/V2MacPrivilegedHelper"
cp -f "$SRCROOT/PrivilegedHelper/LaunchDaemon.plist" "$DAEMONS/$SERVICE.plist"
/usr/libexec/PlistBuddy \
  -c "Set :Label $SERVICE" \
  -c 'Delete :MachServices' \
  -c 'Add :MachServices dict' \
  -c "Add :MachServices:$SERVICE bool true" \
  -c "Set :AssociatedBundleIdentifiers:0 $PRODUCT_BUNDLE_IDENTIFIER" \
  "$DAEMONS/$SERVICE.plist"
/usr/bin/codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier "$SERVICE" "$TOOLS/V2MacPrivilegedHelper"
