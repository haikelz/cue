#!/bin/sh
# Regenerate AppIcon.icns, menubar.tiff and agent-claude.png from the SVG sources. Needs rsvg-convert (brew install librsvg).
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
# The menubar mark as a 1x + 2x TIFF. A PDF would be vector, but converting the SVG's masks (the cut
# around the dot and the prompt) to PDF loses them in NSImage.
rsvg-convert -w 18 menubar.svg -o "$tmp/menubar.png"
rsvg-convert -w 36 menubar.svg -o "$tmp/menubar@2x.png"
tiffutil -cathidpicheck "$tmp/menubar.png" "$tmp/menubar@2x.png" -out menubar.tiff 2> /dev/null
# The agents' logos, 64 px for a 20 pt icon on a Retina screen. Codex's and Amp's come as PNGs from
# their makers (the Codex editor extension, ampcode.com); Claude's starburst comes as an SVG.
rsvg-convert -w 64 -h 64 agent-claude.svg -o agent-claude.png
rm -rf "$tmp"
