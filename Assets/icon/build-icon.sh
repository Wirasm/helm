#!/bin/bash
# Rebuild Assets/helm.icns from Assets/icon/helm.svg.
#
# NOT part of the gate, and deliberately so: this needs `rsvg-convert` (Homebrew librsvg)
# and `iconutil`, and AGENTS.md is explicit that the gate takes only the Swift toolchain and
# xcodegen — "every dependency added to it is a dependency every contributor now needs".
# So `helm.icns` is a COMMITTED artifact and this script is how you regenerate it after
# editing the SVG. Run it by hand; the build never does.
#
#   bash Assets/icon/build-icon.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
svg="$here/helm.svg"
icns="$root/Assets/helm.icns"

command -v rsvg-convert >/dev/null || {
	echo "need rsvg-convert: brew install librsvg" >&2
	exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set="$work/helm.iconset"
mkdir -p "$set"

# The ten sizes macOS actually asks for. Each is rendered from the vector rather than
# downscaled from one raster: a 16px bitmap resampled from 1024 is mush, and 16px is the
# size that decides whether this mark works at all.
render() { rsvg-convert -w "$1" -h "$1" "$svg" -o "$set/$2"; }
render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns "$set" --output "$icns"
echo "wrote $icns ($(du -h "$icns" | cut -f1))"
