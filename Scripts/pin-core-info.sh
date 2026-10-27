#!/bin/bash
# Xcode build phase: writes the pinned core and the core versions this build accepts (core.lock) into
# Info.plist, where the app reads them at launch (spec 11.1, `CorePin`).
set -euo pipefail
source "$SRCROOT/Scripts/core.lock"
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
plutil -replace V2MacCoreVersion -string "$VERSION" "$PLIST"
plutil -replace V2MacCoreSHA256 -string "$SHA256" "$PLIST"
plutil -replace V2MacCoreMin -string "$MIN" "$PLIST"
plutil -replace V2MacCoreMaxExclusive -string "$MAX_EXCLUSIVE" "$PLIST"
