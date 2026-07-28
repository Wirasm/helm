# AGENTS.md — helm

helm is the native macOS cockpit for the sild stack: SwiftUI + GhosttyKit. One surface —
sidebar (observe/steer rooms), terminal center, shared right dock (room detail or
artifact). The kild engine's REST/WS API (`localhost:4517`) is the ONLY backend;
artifacts are plain files under `~/.prp/<key>/`. helm knows prp and kild; they never
know helm.

## How to work here

- Layout: `Sources/Helm/` (flat), `Tests/HelmTests/`
- Work in a git worktree on a branch, one testable piece, PR to `development`.
- Gates: `bash scripts/patch-libghostty.sh && swift build && swift test && make lint && xcodegen generate`
  — all green before any PR. The patch script comes first and is not optional: the
  vendored, patched libghostty is gitignored, so a fresh worktree has no dependency to
  link against. Never borrow another checkout's `vendor/` to get a green gate — that
  proves the other checkout builds, not yours.
- **Never delete an existing test to make a gate green.** If a test is genuinely obsolete
  because the behaviour it covered no longer exists, say which and why in the commit
  message. A total that went up while a file's coverage went down is not a pass.
- Build, test and run freely. The one restriction: **never restart a running helm without
  warning the operator first** — a live window may be hosting their session.
- Visual verification: `make app`, then `open Helm.app --args --kild <id> / --artifact <path>`.
  `swift tools/winshot.swift helm out.png` captures it — but **capture needs a Screen Recording
  grant the agent contexts do not have and cannot give themselves**, so an unattended run
  cannot see the UI. Ask the operator; do not report a surface as verified without it.
  `swift tools/winshot.swift --list helm` needs no grant and reports pid, layer and bounds —
  enough to tell a real window from a crash, a zero-sized one or an off-screen one, and
  nothing at all about what is drawn in it. The accessibility API is **not** a way around
  this: helm's SwiftUI content exposes no children to it, verified by walking a known-good
  build that renders fine and getting the same empty tree.
- `swift run helm` for iteration; `make app` for the real bundle (notifications need it).
- Conventional commits, written as a human — no AI attribution, no Co-Authored-By.
