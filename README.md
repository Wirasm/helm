# helm

The native macOS cockpit for the sild stack: a libghostty terminal as the main view
(your driver — pi/claude/codex — runs here), toggling into the kild view (rooms,
decisions, artifacts). The kild engine's REST/WS API is the ONLY backend contract;
artifacts are read from the filesystem (`~/.prp/<key>/`). helm knows both prp and
kild — they never know helm or each other.

Status: **libghostty spike** — see `docs/SPIKE.md`.

Run: `swift run helm` (needs the kild engine on localhost:4517 for the kild view;
the terminal pane is a real GhosttyKit surface via libghostty-spm — no toolchain needed,
SPM fetches the prebuilt xcframework).

Seed plan: `docs/ui-plan.md` (inherited from the kild cockpit era; the three 2026-07-24 addenda are the current direction).
