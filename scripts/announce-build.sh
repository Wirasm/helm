#!/usr/bin/env bash
# Tell a running helm that a newer build exists.
#
# WHY THE BUILD ANNOUNCES AND THE INSTALL DOES NOT. Watching /Applications/Helm.app cannot
# work: that bundle only changes when `make install` copies over it, and `make install`
# refuses while helm is running. By the time the installed bundle moves, the operator has
# already quit and the question has answered itself. The build is the step that happens
# *while* helm runs — an agent building on a branch is the normal case here — so the build is
# what leaves the note.
#
# Writes the format `BuildStamp` decodes. That type and this script are the two halves of one
# wire format across a runtime boundary a Swift library cannot cross, which is the same
# carve-out AGENTS.md grants the spool scripts and the mailbox — and, like those, it is
# detectable rather than trusted: `BuildStampScriptTests` runs this script and decodes what it
# writes with the real type.
set -euo pipefail

product="${1:?usage: announce-build.sh <path to built Helm.app>}"

if [ ! -d "$product" ]; then
  echo "announce-build: $product is not a bundle on disk" >&2
  exit 1
fi

# Read the sha back OUT of the bundle rather than asking git a second time. The stamp and the
# announcement then agree by construction: there is one derivation (stamp-build.sh) and this
# reports it. Two independent `git rev-parse` calls would be two spellings of one fact, free
# to drift the moment either grows a rule the other lacks — a dirty-tree suffix, say.
plist="$product/Contents/Info.plist"
if ! sha=$(/usr/libexec/PlistBuddy -c "Print :HelmBuildSHA" "$plist" 2>/dev/null); then
  echo "announce-build: $product carries no HelmBuildSHA — nothing to announce" >&2
  exit 0
fi

dir="${HELM_BUILD_DIR:-$HOME/.helm/build}"
mkdir -p "$dir"
chmod 700 "$dir"

built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
target="$dir/latest.json"
staged="$target.tmp.$$"

# Atomic replace: a helm polling this file must never read half of it. It polls rather than
# watches precisely because this path is rewritten in place, so a torn read is the failure
# mode to design out.
cat >"$staged" <<JSON
{
  "format": "helm.build-stamp",
  "version": 1,
  "sha": "$sha",
  "builtAt": "$built_at",
  "product": "$product"
}
JSON

chmod 600 "$staged"
mv -f "$staged" "$target"

echo "announced $sha at $target"
