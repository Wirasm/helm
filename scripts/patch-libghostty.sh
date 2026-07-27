#!/usr/bin/env bash
# Materialize the patched libghostty-spm that Package.swift / project.yml point at.
# Clones upstream at the pinned tag into vendor/ (gitignored) and applies
# Patches/libghostty-spm-multi-surface-wakeup.patch — the multi-surface wakeup fix
# (docs/VENDORED.md). TEMPORARY: this local path pin exists only until the patch
# lives in a real fork or upstream; see docs/VENDORED.md for the retirement path.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/vendor/libghostty-spm"
tag=1.3.1
patch="$root/Patches/libghostty-spm-multi-surface-wakeup.patch"

[ -f "$patch" ] || { echo "missing $patch"; exit 1; }

if [ -d "$vendor" ]; then
  echo "vendor/libghostty-spm already exists — remove it to re-clone"
  exit 0
fi

git clone https://github.com/Lakr233/libghostty-spm.git "$vendor"
cd "$vendor"
git checkout -b helm/multi-surface-wakeup "$tag"
git am "$patch"
echo "OK: $vendor @ $(git rev-parse --short HEAD) (base $tag)"
echo "Verify: (cd '$vendor' && swift test --filter TerminalLifecycle)"
