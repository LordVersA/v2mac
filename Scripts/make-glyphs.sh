#!/bin/bash
# Renders the menu bar glyph SVGs in Design/ into template-image PDFs in the asset catalog.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/App/Resources/Assets.xcassets"
for variant in Filled Outline; do
  lower=$(echo "$variant" | tr 'A-Z' 'a-z')
  set_dir="$CATALOG/MenuBarGlyph$variant.imageset"
  mkdir -p "$set_dir"
  rsvg-convert -f pdf -o "$set_dir/glyph-$lower.pdf" "$ROOT/Design/menubar-glyph-$lower.svg"
  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [ { "filename" : "glyph-$lower.pdf", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" }
}
JSON
done
echo "glyphs written to $CATALOG"
