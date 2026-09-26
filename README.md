# helm

The native macOS surface you work in: libghostty terminals where your CLI agent (pi,
Claude Code, codex) runs, arranged with the files it writes into a workbench — columns of
tabbed slots, several panes on screen at once — with workspaces above it. Markdown and
HTML are rendered from the filesystem; there is no backend.

"Agent" always means a CLI agent you already run. helm hosts it in a terminal it owns and
renders what it writes. It does not build or host an agent of its own.

Status: **rebuilding.** The kild layer was removed — see `docs/direction.md` for where
this is going, and `docs/SPIKE.md` for the terminal lifecycle contract that everything
else rests on.

## Running

- `swift run helm` (or `make run`) — fast SPM iteration loop; no bundle, no signing.
- `make app` — the real Helm.app bundle via XcodeGen (`project.yml` → Helm.xcodeproj
  → xcodebuild; needs `xcodegen`). The target echoes the built .app path.
- `make build` / `make test` / `make lint` / `make clean`.

Both paths build the same sources against the same local package, `Packages/GhosttyTerminal`
(named in `Package.swift` AND `project.yml`). The terminal is a real GhosttyKit surface:
official Ghostty, built by us at a pinned commit and fetched prebuilt by SPM, so no zig is
needed to build helm. `docs/VENDORED.md` ("Ghostty") says how the pin moves.
