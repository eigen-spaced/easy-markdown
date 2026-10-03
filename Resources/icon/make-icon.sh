#!/bin/sh
# Regenerates AppIcon.icns from AppIcon.svg. Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")"
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size AppIcon.svg -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) AppIcon.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "Wrote $(pwd)/AppIcon.icns"
