#!/bin/sh
set -eu

# Baton app-icon generator — adapted from Tonebox's scripts/generate-app-icons.sh.
# Renders the transparent master SVG into a macOS AppIcon.appiconset via rsvg-convert.
# Usage: design/generate-app-icons.sh   (run from anywhere)

DESIGN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$DESIGN_DIR/.." && pwd)
SOURCE="$DESIGN_DIR/Baton.master.svg"
SOURCE_16="$DESIGN_DIR/Baton.master-16pt.svg"   # simplified 2-line variant for tiny sizes
MAC_DIR="$APP_ROOT/app/Assets.xcassets/AppIcon.appiconset"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "rsvg-convert is required (brew install librsvg)" >&2
  exit 1
}

mkdir -p "$MAC_DIR"

render() {
  rsvg-convert -w "$1" -h "$1" "$SOURCE" -o "$2"
}

render16() {
  rsvg-convert -w "$1" -h "$1" "$SOURCE_16" -o "$2"
}

# macOS AppIcon catalog (transparent PNGs).
for size in 16 32 64 128 256 512 1024; do
  render "$size" "$TMP/mac-$size.png"
done
# The two 16pt slots (16x16 @1x = 16px, @2x = 32px) use the simplified 2-line variant.
render16 16 "$TMP/mac16-16.png"
render16 32 "$TMP/mac16-32.png"
cp "$TMP/mac16-16.png" "$MAC_DIR/icon_16x16.png"
cp "$TMP/mac16-32.png" "$MAC_DIR/icon_16x16@2x.png"
cp "$TMP/mac-32.png"   "$MAC_DIR/icon_32x32.png"
cp "$TMP/mac-64.png"   "$MAC_DIR/icon_32x32@2x.png"
cp "$TMP/mac-128.png"  "$MAC_DIR/icon_128x128.png"
cp "$TMP/mac-256.png"  "$MAC_DIR/icon_128x128@2x.png"
cp "$TMP/mac-256.png"  "$MAC_DIR/icon_256x256.png"
cp "$TMP/mac-512.png"  "$MAC_DIR/icon_256x256@2x.png"
cp "$TMP/mac-512.png"  "$MAC_DIR/icon_512x512.png"
cp "$TMP/mac-1024.png" "$MAC_DIR/icon_512x512@2x.png"

# Contents.json for the catalog.
cat > "$MAC_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",     "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",  "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",     "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",  "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",   "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png","scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",   "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png","scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",   "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png","scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

# Design preview (transparent) at 512 and 1024.
render 1024 "$DESIGN_DIR/Baton.preview.png"

echo "Generated Baton macOS icons into $MAC_DIR from $SOURCE"
