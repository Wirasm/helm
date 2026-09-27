#!/usr/bin/env bash
# The daemon gate — the pi/-style carve-out: run when daemon/ changed, needs only the
# Rust toolchain, and the Swift gate never learns about it (bench-roadmap, invariant 9).
#
# Order matters: build the whole workspace BEFORE testing, because the conformance suite
# runs the real benchd binary as a subprocess and locates it beside its own — a test run
# without the build finds nothing and says so.
set -euo pipefail
cd "$(dirname "$0")"

# The VT engine's archives are pinned by hash, and built from the Ghostty commit helm's
# GhosttyKit is: what an agent reads off a session is what the operator's Ghostty draws.
(cd vendor/libghostty-vt && shasum -a 256 -c --quiet SHA256SUMS)
want=$(sed -n 's/^let ghosttyCommit = "\(.*\)"/\1/p' ../Packages/GhosttyTerminal/Package.swift)
have=$(cat vendor/libghostty-vt/GHOSTTY_COMMIT)
if [ "$want" != "$have" ]; then
  echo "daemon/vendor/libghostty-vt is Ghostty $have, helm's GhosttyKit is $want:" \
    "scripts/bump-ghostty.sh moves both" >&2
  exit 1
fi

cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo build --workspace
cargo test --workspace
