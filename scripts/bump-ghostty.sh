#!/usr/bin/env bash
# Move helm to a Ghostty commit: build GhosttyKit.xcframework from official Ghostty,
# publish it, repin, and refresh everything else that must match that commit.
#
#   scripts/bump-ghostty.sh [<ghostty commit>]   default: ghostty-org/ghostty main, now
#   scripts/bump-ghostty.sh --no-publish [...]   build and repin to a local zip only
#
# Needs zig at Ghostty's minimum_zig_version, Xcode with the Metal toolchain
# (`xcodebuild -downloadComponent MetalToolchain`), and `gh` logged in to Wirasm/helm.
# The gate needs none of this: it downloads the published zip by URL and checksum.
#
# One commit, three consumers, and this script moves the first two together
# (docs/VENDORED.md, "Ghostty"):
#   1. GhosttyKit.xcframework  -> release ghostty-<commit12> on Wirasm/helm, pinned in
#                                 Packages/GhosttyTerminal/Package.swift
#   2. shell integration       -> Sources/Helm/Resources/ghostty/shell-integration/
#   3. benchd's libghostty-vt  -> not in the tree yet (M5b). When it is, it is built from
#                                 the same source tree this script checks out:
#                                 `zig build -Demit-lib-vt` in "$src".
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$root/Packages/GhosttyTerminal/Package.swift"
integration="$root/Sources/Helm/Resources/ghostty/shell-integration"
repo=Wirasm/helm

publish=yes
if [ "${1:-}" = --no-publish ]; then
  publish=no
  shift
fi

commit=${1:-}
if [ -z "$commit" ]; then
  commit=$(git ls-remote https://github.com/ghostty-org/ghostty.git refs/heads/main | cut -f1)
fi
case "$commit" in
  *[!0-9a-f]* | "") echo "bump-ghostty: '$commit' is not a full commit sha" >&2; exit 1 ;;
esac
[ ${#commit} -eq 40 ] || { echo "bump-ghostty: give the full 40-character sha" >&2; exit 1; }
short=${commit:0:12}
tag="ghostty-$short"

# The checkout lives under .build/ (gitignored) so a rerun reuses zig's cache.
src="$root/.build/ghostty/$short"
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$src" fetch -q --depth 1 origin "$commit"
git -C "$src" checkout -q --force FETCH_HEAD

want_zig=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$src/build.zig.zon")
have_zig=$(zig version 2>/dev/null || echo none)
if [ "$have_zig" != "$want_zig" ]; then
  echo "bump-ghostty: Ghostty $short needs zig $want_zig, found $have_zig" >&2
  exit 1
fi

echo "--> building GhosttyKit.xcframework at $short (zig $have_zig)"
(cd "$src" && zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Dxcframework-target=universal -Demit-macos-app=false)

# SwiftPM refuses a static library whose name lacks the `lib` prefix, and Ghostty names its
# `ghostty-internal.a` (Xcode does not care). Renaming the file and the two plist keys that
# point at it is packaging, not a change to what Ghostty built.
stage="$src/stage"
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$src/macos/GhosttyKit.xcframework" "$stage/"
plist="$stage/GhosttyKit.xcframework/Info.plist"
count=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$plist" | grep -c LibraryIdentifier)
for ((i = 0; i < count; i++)); do
  dir=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryIdentifier" "$plist")
  lib=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryPath" "$plist")
  case "$lib" in lib*) continue ;; esac
  mv "$stage/GhosttyKit.xcframework/$dir/$lib" "$stage/GhosttyKit.xcframework/$dir/libghostty.a"
  /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:$i:LibraryPath libghostty.a" \
    -c "Set :AvailableLibraries:$i:BinaryPath libghostty.a" "$plist"
done

zip="$src/GhosttyKit.xcframework.zip"
rm -f "$zip"
(cd "$stage" && ditto -c -k --keepParent GhosttyKit.xcframework "$zip")
checksum=$(swift package compute-checksum "$zip")
echo "--> $zip"
echo "    sha256 $checksum"

if [ "$publish" = yes ]; then
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "bump-ghostty: release $tag already exists; its asset is what the pin must match." >&2
    echo "              Delete it first to replace the build, or pin to it by hand." >&2
    exit 1
  fi
  gh release create "$tag" "$zip" --repo "$repo" --prerelease --latest=false \
    --title "Ghostty $short (GhosttyKit for helm)" \
    --notes "GhosttyKit.xcframework built unpatched from ghostty-org/ghostty@$commit with zig $have_zig by scripts/bump-ghostty.sh. A vendored build artifact, not a helm release. sha256 $checksum"
fi

# The pin is two lines; the release URL is derived from the commit in the manifest itself.
sed -i '' \
  -e "s/^let ghosttyCommit = \".*\"/let ghosttyCommit = \"$commit\"/" \
  -e "s/^let ghosttyKitChecksum = \".*\"/let ghosttyKitChecksum = \"$checksum\"/" \
  "$manifest"
grep -q "\"$commit\"" "$manifest" && grep -q "\"$checksum\"" "$manifest" || {
  echo "bump-ghostty: failed to rewrite the pin in $manifest" >&2
  exit 1
}

# Copied verbatim: helm points GHOSTTY_RESOURCES_DIR at this tree, and the scripts must be
# the ones the binary above was built with.
rsync -a --delete "$src/src/shell-integration/" "$integration/"

echo "--> pinned Ghostty $commit"
echo "Next: just check  (a changed ghostty.h fails the build in Packages/GhosttyTerminal),"
echo "      then look at a live isolated helm before trusting it (docs/VENDORED.md)."
