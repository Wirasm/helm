# AGENTS.md — helm

helm is the native macOS cockpit for the sild stack: SwiftUI + GhosttyKit. One surface —
sidebar (observe/steer rooms), terminal center, shared right dock (room detail or
artifact). The kild engine's REST/WS API (`localhost:4517`) is the ONLY backend;
artifacts are plain files under `~/.prp/<key>/`. helm knows prp and kild; they never
know helm.

## How to work here

- Layout: `Sources/Helm/` (flat), `Tests/HelmTests/`
- Work in a git worktree on a branch, one testable piece, PR to `development`.
- Gates: `bash scripts/patch-libghostty.sh && swift build && swift test && xcodegen generate`
  — all green before any PR. The patch script comes first and is not optional: the
  vendored, patched libghostty is gitignored, so a fresh worktree has no dependency to
  link against. Never borrow another checkout's `vendor/` to get a green gate — that
  proves the other checkout builds, not yours.
- **Never delete an existing test to make a gate green.** If a test is genuinely obsolete
  because the behaviour it covered no longer exists, say which and why in the commit
  message. A total that went up while a file's coverage went down is not a pass.
- Build, test and run freely. The one restriction: **never restart a running helm without
  warning the operator first** — a live window may be hosting their session. Visual
  verification: `make app`, then `open Helm.app --args --room <id> / --artifact <path>`,
  capture with `swift tools/winshot.swift helm out.png` (window owner is lowercase "helm").
- `swift run helm` for iteration; `make app` for the real bundle (notifications need it).
- Conventional commits, written as a human — no AI attribution, no Co-Authored-By.
