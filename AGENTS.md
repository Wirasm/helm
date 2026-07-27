# AGENTS.md — helm

helm is the native macOS cockpit for the sild stack: SwiftUI + GhosttyKit. One surface —
sidebar (observe/steer rooms), terminal center, shared right dock (room detail or
artifact). The kild engine's REST/WS API (`localhost:4517`) is the ONLY backend;
artifacts are plain files under `~/.prp/<key>/`. helm knows prp and kild; they never
know helm.

## Boundaries (violations are bugs)

- **The terminal is the center of attention** — never hidden, never swapped, never below
  comfort width. Esc is never intercepted globally (TUIs own it).
- **ptys outlive everything**: TerminalManager owns sessions + NSViews app-level; views
  are mounted, never recreated. ONE shared TerminalController — one `ghostty_app_t` —
  owned by TerminalManager, with a surface per terminal (see the TerminalManager
  header; it depends on the vendored wakeup patch in `docs/VENDORED.md`).
- **EngineClient is the single API surface** — no view fetches directly.
- **Attention is a state of existing elements, never an added element**: chips change
  color, rows gain an edge, one indicator slot per tab with fixed precedence. No badges,
  no popups.
- Vendored pins (libghostty-spm, marked, mermaid, shell-integration scripts) are exact
  and recorded in `docs/VENDORED.md`; deps/resources live in BOTH `Package.swift` and
  `project.yml`, in lockstep. No runtime network fetches; webviews render local content only.
- Vocabulary: `../GLOSSARY.md` is law.

## How to work here

- Layout: `Sources/Helm/` (flat), `Tests/HelmTests/`, `docs/ui-plan.md` (the plan and
  its append-only history — update it when a slice ships), `tools/` (dev harness).
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
