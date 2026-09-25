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
- `crates/bench-session` — the pty core: agent allowlist, postures/model/effort/resume
  argv (one spelling, unit-tested), the ring, the attach relay, drain-then-die close.
- `crates/benchd` — the daemon. Foreground, one unix socket, a thread per connection.
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
- **Wire changes ride with their conformance test** in `crates/bench/tests/` — real
  binaries, both directions, every status case, same as `SpoolWireConformanceTests`.
- Conventional commits, written as a human — no AI attribution (repo rule).
