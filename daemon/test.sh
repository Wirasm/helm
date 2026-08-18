#!/usr/bin/env bash
# The daemon gate — the pi/-style carve-out: run when daemon/ changed, needs only the
# Rust toolchain, and the Swift gate never learns about it (bench-roadmap, invariant 9).
#
# Order matters: build the whole workspace BEFORE testing, because the conformance suite
# runs the real benchd binary as a subprocess and locates it beside its own — a test run
# without the build finds nothing and says so.
set -euo pipefail
cd "$(dirname "$0")"

cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo build --workspace
cargo test --workspace
