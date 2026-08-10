#!/usr/bin/env bash
# Materialize the patched libghostty-spm that Package.swift / project.yml point at.
# Clones upstream at the pinned commit into vendor/ (gitignored) and applies every
# patch in Patches/, in order (docs/VENDORED.md). TEMPORARY: this local path pin
# exists only until the patches live in a real fork or upstream; see
# docs/VENDORED.md for the retirement path.
#
# A path dependency does not appear in Package.resolved, so this script IS the
# pin — which is why it checks out an immutable SHA rather than a tag, and why
# it verifies an existing vendor/ instead of assuming it is correct.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/vendor/libghostty-spm"

# Tag 1.3.1's commit, pinned by SHA: a tag can be moved, and the whole point of
# the vendored-pin discipline (AGENTS.md, docs/VENDORED.md) is that it cannot.
base=b0930320739324886590e865d571eb5dd7073912
base_tag=1.3.1

# The patches, in apply order, each with the symbol that proves IT applied and the
# file that symbol lives in. One marker per patch and not one for the set: a
# vendor/ carrying only the first patch is exactly the stale tree this script
# exists to catch, and a single marker cannot tell that apart from a correct one.
#
#   <patch file>|<marker symbol>|<file the symbol is in>
patches=(
  "libghostty-spm-multi-surface-wakeup.patch|wakeupSubscribers|Sources/GhosttyTerminal/Controller/TerminalController.swift"
  "libghostty-spm-clipboard-destination.patch|TerminalClipboardDestination|Sources/GhosttyTerminal/Controller/TerminalController+Callbacks.swift"
)

for entry in "${patches[@]}"; do
  patch_file="$root/Patches/${entry%%|*}"
  [ -f "$patch_file" ] || { echo "missing $patch_file" >&2; exit 1; }
done

# Every patch's marker is present in the tree at "$1", or a nonzero return says
# which one is missing.
check_markers() {
  local tree="$1" entry rest name marker marker_file
  for entry in "${patches[@]}"; do
    name="${entry%%|*}"
    rest="${entry#*|}"
    marker="${rest%%|*}"
    marker_file="${rest#*|}"
    if ! grep -q "$marker" "$tree/$marker_file" 2>/dev/null; then
      echo "$name"
      return 1
    fi
  done
  return 0
}

if [ -d "$vendor" ]; then
  # Verify, never assume. A vendor/ left over from an older revision of the
  # patch would otherwise build silently against the wrong source and report
  # success — the exact failure this pin exists to prevent.
  if ! git -C "$vendor" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: $vendor exists but is not a git clone." >&2
    echo "       Remove it and re-run to re-clone." >&2
    exit 1
  fi
  if ! git -C "$vendor" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    echo "ERROR: $vendor is not based on the pinned commit $base ($base_tag)." >&2
    echo "       Remove it and re-run to re-clone." >&2
    exit 1
  fi
  if ! missing=$(check_markers "$vendor"); then
    echo "ERROR: $vendor exists but $missing is NOT applied." >&2
    echo "       Remove it and re-run to re-clone." >&2
    exit 1
  fi
  echo "OK: $vendor verified — based on ${base:0:7} ($base_tag), ${#patches[@]} patches applied"
  exit 0
fi

git clone https://github.com/Lakr233/libghostty-spm.git "$vendor"
git -C "$vendor" checkout -b helm/patches "$base"
for entry in "${patches[@]}"; do
  git -C "$vendor" am "$root/Patches/${entry%%|*}"
done

# Same verification the existing-clone path runs, so a silently-failed apply
# can never look like success.
if ! missing=$(check_markers "$vendor"); then
  echo "ERROR: patches applied but $missing left no marker behind." >&2
  exit 1
fi

echo "OK: $vendor @ $(git -C "$vendor" rev-parse --short HEAD) (base ${base:0:7} / $base_tag)"
echo "Verify: (cd '$vendor' && swift test --filter TerminalLifecycle)"
echo "        (cd '$vendor' && swift test --filter TerminalClipboardDestination)"
