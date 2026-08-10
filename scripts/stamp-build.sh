#!/usr/bin/env bash
# Write the commit a bundle was built from into its own Info.plist.
#
# Runs as the Helm target's last build phase (project.yml `postBuildScripts`), which is
# before Xcode's implicit code-signing task rather than after it — the ordering the whole
# approach depends on, since a plist edited after signing invalidates the signature.
# `make release` proves it: it runs `codesign --verify` on the product afterwards.
#
# WHY BAKE IT AT ALL. An installed helm in /Applications has no checkout to ask which commit
# it came from, and the tempting proxy — compare the bundle's mtime against the stamp's
# builtAt — measures when it was *copied*, not when it was built. `cp -R` does not preserve
# mtimes, so on the one path that matters those two differ.
#
# The key name is spelled here and in `RunningBuild.shaKey`, and nowhere else.
# `BuildStampScriptTests` runs this script and reads the key back, so a rename on either side
# fails a test instead of silently producing a helm that can never see an update.
set -euo pipefail

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# A build from an export, a tarball, or a tree with no git at all still has to produce a
# working app — it just produces one that never offers an update, which is exactly what
# `BuildUpdate.decide` does with a nil sha. Failing the build here would be trading a real
# capability for a cosmetic one.
if ! sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null); then
  echo "warning: no git commit for $root — build will carry no update identity" >&2
  exit 0
fi

# A working tree with edits is not the commit it claims to be, and two builds that differ
# must not present the same identity. The honest limit, recorded rather than hidden: two
# *dirty* builds of the same commit share `<sha>-dirty` and so do not raise a badge against
# each other. That is the iteration path, where `swift run helm` (unstamped, never badges) is
# what anyone is actually using.
if ! git -C "$root" diff --quiet HEAD 2>/dev/null; then
  sha="${sha}-dirty"
fi

/usr/libexec/PlistBuddy -c "Add :HelmBuildSHA string $sha" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :HelmBuildSHA $sha" "$plist"

echo "stamped $plist with HelmBuildSHA=$sha"
