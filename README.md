# helm

The native macOS cockpit for the sild stack: a libghostty terminal as the main view
(your operator — pi/claude/codex — runs here), toggling into the kild view (rooms,
decisions, artifacts). The kild engine's REST/WS API is the ONLY backend contract;
artifacts are read from the filesystem (`~/.prp/<key>/`). helm knows both prp and
kild — they never know helm or each other.

Status: **libghostty spike** — see `docs/SPIKE.md`.

## Running

- `swift run helm` (or `make run`) — fast SPM iteration loop; no bundle, no signing.
- `make app` — the real Helm.app bundle via XcodeGen (`project.yml` → Helm.xcodeproj
  → xcodebuild; needs `xcodegen`). The target echoes the built .app path.
- `make build` / `make test` / `make clean` — SPM build, tests, and cleanup.

Both paths build the same sources against the same pinned libghostty-spm (exact
1.3.1 in `Package.swift` AND `project.yml` — keep them in lockstep). The kild view
needs the kild engine on localhost:4517; the terminal pane is a real GhosttyKit
surface via libghostty-spm — no toolchain needed, SPM fetches the prebuilt
xcframework.

Seed plan: `docs/ui-plan.md` (inherited from the kild cockpit era; the three 2026-07-24 addenda are the current direction).
