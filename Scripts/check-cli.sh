#!/bin/bash
set -euo pipefail

app="${1:?usage: check-cli.sh /path/to/V2Mac.app}"
cli="$app/Contents/Helpers/v2mac"
test -x "$cli"
/usr/bin/codesign --verify --strict "$cli"
/usr/bin/codesign --verify --deep --strict "$app"
test "$(/usr/bin/codesign -d --entitlements - "$cli" 2>&1 | /usr/bin/grep -c get-task-allow || true)" -eq 0
/usr/bin/grep -q 'binary "V2Mac.app/Contents/Helpers/v2mac"' "$(dirname "$0")/../../homebrew-tap/Casks/v2mac.rb"
