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
  are mounted, never recreated. Terminals are grouped per workspace, but ONE shared
  TerminalController — one `ghostty_app_t` — owns every surface (see the TerminalManager
  header; it depends on the vendored wakeup patch in `docs/VENDORED.md`). Switching
  workspaces parks views; it never tears down a pty. Workspace `⌃1–9` shortcuts require
  handing those Mission Control bindings over in System Settings; `⌘⌥1–9` is the fallback.
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
- Gates: `swift build`, `swift test`, `xcodegen generate` — all green before any PR.
- NEVER launch the GUI from automation. Visual verification: build with `make app`,
  launch via `open Helm.app --args --room <id> / --artifact <path>`, capture with
  `swift tools/winshot.swift helm out.png` (window owner is lowercase "helm").
- `swift run helm` for iteration; `make app` for the real bundle (notifications need it).
- Conventional commits, written as a human — no AI attribution, no Co-Authored-By.
