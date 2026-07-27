#!/usr/bin/env bash
# Materialize the patched libghostty-spm that Package.swift / project.yml point at.
# Clones upstream at the pinned commit into vendor/ (gitignored) and applies
# Patches/libghostty-spm-multi-surface-wakeup.patch — the multi-surface wakeup fix
# (docs/VENDORED.md). TEMPORARY: this local path pin exists only until the patch
# lives in a real fork or upstream; see docs/VENDORED.md for the retirement path.
#
# A path dependency does not appear in Package.resolved, so this script IS the
# pin — which is why it checks out an immutable SHA rather than a tag, and why
# it verifies an existing vendor/ instead of assuming it is correct.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/vendor/libghostty-spm"
patch="$root/Patches/libghostty-spm-multi-surface-wakeup.patch"

# Tag 1.3.1's commit, pinned by SHA: a tag can be moved, and the whole point of
# the vendored-pin discipline (AGENTS.md, docs/VENDORED.md) is that it cannot.
base=b0930320739324886590e865d571eb5dd7073912
base_tag=1.3.1

# Proof the patch is applied — the symbol it introduces.
marker=wakeupSubscribers
marker_file=Sources/GhosttyTerminal/Controller/TerminalController.swift

[ -f "$patch" ] || { echo "missing $patch" >&2; exit 1; }

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
  if ! grep -q "$marker" "$vendor/$marker_file" 2>/dev/null; then
    echo "ERROR: $vendor exists but the multi-surface wakeup patch is NOT applied." >&2
    echo "       Remove it and re-run to re-clone." >&2
    exit 1
  fi
  echo "OK: $vendor verified — based on ${base:0:7} ($base_tag), patch applied"
  exit 0
fi

git clone https://github.com/Lakr233/libghostty-spm.git "$vendor"
git -C "$vendor" checkout -b helm/multi-surface-wakeup "$base"
git -C "$vendor" am "$patch"

# Same verification the existing-clone path runs, so a silently-failed apply
# can never look like success.
grep -q "$marker" "$vendor/$marker_file" || {
  echo "ERROR: patch applied but $marker is missing from $marker_file." >&2
  exit 1
}

echo "OK: $vendor @ $(git -C "$vendor" rev-parse --short HEAD) (base ${base:0:7} / $base_tag)"
echo "Verify: (cd '$vendor' && swift test --filter TerminalLifecycle)"
