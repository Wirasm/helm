# helm

The native macOS surface you work in: a libghostty terminal as the permanent centre —
your CLI agent (pi, Claude Code, codex) runs here — with workspaces above it and a right
dock for an open artifact. Markdown and HTML are rendered from the filesystem; there is
no backend.

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

Both paths build the same sources against the same pinned libghostty-spm (exact 1.3.1 in
`Package.swift` AND `project.yml` — keep them in lockstep). The terminal is a real
GhosttyKit surface; no toolchain needed, SPM fetches the prebuilt xcframework.
