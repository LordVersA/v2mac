#!/bin/bash
set -euo pipefail

source_path="${BUILT_PRODUCTS_DIR}/v2mac"
destination_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$destination_dir"
cp "$source_path" "$destination_dir/v2mac"
chmod 755 "$destination_dir/v2mac"
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.cli" "$destination_dir/v2mac"
fi
