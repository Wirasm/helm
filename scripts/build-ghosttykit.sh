#!/usr/bin/env bash
# Build GhosttyKit.xcframework for helm's TerminalPane (see docs/SPIKE.md).
# Clones ghostty into vendor/ (gitignored) and builds the xcframework the same way
# Ghostty's own macOS app does. Requires the zig version ghostty pins — the build
# errors loudly on mismatch; install the pinned version if brew's is wrong.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/vendor/ghostty"

command -v zig >/dev/null || { echo "zig not found — brew install zig (check ghostty's pinned version first)"; exit 1; }

if [ ! -d "$vendor" ]; then
  git clone --depth 1 https://github.com/ghostty-org/ghostty "$vendor"
fi

cd "$vendor"
echo "ghostty @ $(git rev-parse --short HEAD) · zig $(zig version)"
zig build xcframework

out="$vendor/macos/GhosttyKit.xcframework"
[ -d "$out" ] || { echo "expected $out — check ghostty's current build docs (target may have moved)"; exit 1; }
echo "OK: $out"
echo "Next: add the binaryTarget to Package.swift (docs/SPIKE.md step 3), pin the SHA above in SPIKE.md."
