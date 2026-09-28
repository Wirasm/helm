#!/usr/bin/env bash
# Write the commit a bundle is built from into the Info.plist Xcode builds it from.
#
# Runs as the Helm target's first build phase (project.yml `preBuildScripts`) and writes the
# *source* Info.plist, the file xcodegen generates and ProcessInfoPlistFile reads. That keeps
# processing the only writer of the bundle's Info.plist, so the stamp can neither be
# overwritten by it nor be invisible to the CodeSign task after it (#526). The phase declares
# this file as its output, which is what orders processing after it.
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

root="${SRCROOT:?}"
case "${INFOPLIST_FILE:?}" in
  /*) plist="$INFOPLIST_FILE" ;;
  *) plist="$root/$INFOPLIST_FILE" ;;
esac

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

# Leave the file alone when it already says this: a rewrite would make Xcode reprocess and
# re-sign an unchanged bundle.
if [ "$(/usr/libexec/PlistBuddy -c "Print :HelmBuildSHA" "$plist" 2>/dev/null)" = "$sha" ]; then
  echo "$plist already carries HelmBuildSHA=$sha"
  exit 0
fi

/usr/libexec/PlistBuddy -c "Add :HelmBuildSHA string $sha" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :HelmBuildSHA $sha" "$plist"

echo "stamped $plist with HelmBuildSHA=$sha"
