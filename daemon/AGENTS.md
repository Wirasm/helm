# AGENTS.md — daemon/

The bench daemon: a self-contained cargo workspace, the `pi/`-style carve-out. Read
`direction.md` first; the milestone sequence and invariants are
`../docs/future-planning/bench-roadmap.md`. Vocabulary stays canonical in `../CONTEXT.md`.

## Gate

```
bash daemon/test.sh
```

fmt-check, clippy `-D warnings`, build, then tests — **build before test is load-bearing**:
the conformance suite runs the real `benchd` binary as a subprocess and locates it beside
its own. Run this gate when `daemon/` changed; the Swift gate at the repo root neither
knows nor needs the Rust toolchain, in either direction.

## Layout

- `crates/bench-wire` — every wire type and shared resolution rule, spelled once. If
  `benchd` and `bench` could disagree about a value, its rule belongs here.
- `crates/bench-mail` — the mailroom: delivery, retirement, listings; no sessions, no
  sockets, no wakes — the reactor in `benchd` owns those.
- `crates/bench-doc` — the bench document: workspaces → columns → slots → panes, typed
  surfaces, placement as data, and the focus rule. Pure — no IO, no sockets. Ported from helm's
  `Workbench`; its Swift tests are mirrored in `crates/bench-doc/tests/` under their own names.
  `fixtures/bench-document.json`, `bench-verbs.json` and `bench-frame.json` are pinned by the
  Rust tests byte for byte; helm's Swift decoder will read the same files once M4's client
  lands (PR 3 of #354) — until then only the Rust gate reads them.
- `crates/bench-session` — the pty core: agent allowlist, postures/model/effort/resume
  argv (one spelling, unit-tested), the ring, the attach relay, drain-then-die close.
- `crates/bench-browser` — the shared browser: find, configure and launch one Chromium
  on a pipe leash. Knows no sockets or events; the daemon supervises it.
- `crates/benchd` — the daemon. Foreground, one unix socket, a thread per connection.
  `src/layout.rs` is the bench document's whole mutation path: the layout verbs, `bench.json`,
  and booting from it.
- `crates/bench` — the CLI, the one agent-facing surface, and the attach client.
- There is deliberately **no root `Cargo.toml`** in the repo: `cargo` at the repo root
  fails loudly instead of half-working.

## Rules

- **Bench-visible means logged.** A mutation appends its event before the response that
  reports it. A new capability is new event kinds + new verbs over the same socket —
  never a second channel (no files-as-IPC, no extra sockets, no notification side paths).
- **Tests never touch the operator's estate.** Claim a disposable `HOME` (or `BENCH_DIR`)
  under the OS tempdir — the OS tempdir specifically: unix socket paths cap near 104
  bytes and long scratch paths fail at bind. Include the negative control: assert the
  shared root shape was never created (`hooks/test.sh`'s pattern).
- **Bounded children.** A test that spawns a daemon owns exactly that pid, kills it in a
  Drop guard, and waits. Never kill by pattern (repo root AGENTS.md; #291 is why).
- **Exit codes are the contract**: 0 ok · 2 no daemon · 3 refused · 4 daemon failed.
  A refusal names the rule it applied and the route to use instead.
- **Nothing waits on the disk or on a reader under the core mutex.** The log is written and
  flushed to the kernel before the response, and fsynced every 50 ms by the flusher thread on
  its own descriptor; a follower's frames go through its own bounded queue and are written on
  its own thread. Spike S1 (#354) measured both: an inline fsync per event is 17 ms p99 on a
  single keypress, and a 16 KB frame written under the lock lets one stalled follower freeze
  every verb.
- **Wire changes ride with their conformance test** in `crates/bench/tests/` — real
  binaries, both directions, every status case, same as `SpoolWireConformanceTests`.
- Conventional commits, written as a human — no AI attribution (repo rule).
