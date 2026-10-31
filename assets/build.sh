#!/bin/sh
# Regenerate AppIcon.icns and menubar.pdf from the SVG sources. Needs rsvg-convert (brew install librsvg).
# The generated files are committed, so installing Cue doesn't need this.
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" icon.svg -o "$tmp/AppIcon.iconset/icon_${s}x${s}.png"
  rsvg-convert -w "$((s * 2))" icon.svg -o "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$tmp/AppIcon.iconset" -o AppIcon.icns
rsvg-convert -f pdf menubar.svg -o menubar.pdf
rm -rf "$tmp"
