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
  `fixtures/bench-document.json`, `bench-verbs.json`, `bench-frame.json` and `bench-report.json`
  are pinned by the Rust tests byte for byte, and `bench-report.json` also key for key against a
  live daemon's answers. helm's Swift reads the same four files in `BenchWireConformanceTests`,
  so a change to any of these shapes has to land on both sides of the socket.
- `crates/bench-session` — the pty core: agent allowlist, postures/model/effort/resume
  argv (one spelling, unit-tested), the ring, the attach relay, drain-then-die close.
- `crates/bench-browser` — the shared browser: find, configure and launch one Chromium
  on a pipe leash. Knows no sockets or events; the daemon supervises it.
- `crates/bench-sessions` — the session list (#384): reads Claude Code's registry, `--bg` jobs
  and subagent transcripts, pi's sessions and helm's `snapshot.json`, scopes them to a workspace
  by its git worktrees, and builds typed `SessionRow`s with the one action that opens each. No
  sockets, events or record files — benchd owns `<root>/sessions/hosted.json` and
  `dismissed.json` and logs `sessions/*`. Every harness file it reads is internal and
  undocumented, so a shape it does not know is a skipped row and a `sessions/unreadable` event,
  never a guess. Each row also carries `mail`: the benchd mailbox of a session benchd spawned
  or one whose hook claimed a mailbox through `bench hook` (#358) (handle, `wakeable`,
  `unread`), `null` for everyone else — the list is the mail directory
  too (#396); benchd counts the inboxes and passes them in. `fixtures/session-rows.json`
  pins the reply helm's drawer will decode. `transcript` reads one Claude or pi transcript as
  a log for `bench log` (#421), under the same rule: an unknown record is a named, skipped
  line. Tests
  build fixture trees under a temp HOME; none reads the operator's `~/.claude`, `~/.pi` or
  `~/.helm`.
- `crates/benchd` — the daemon. Foreground, one unix socket, a thread per connection.
  `src/layout.rs` is the bench document's whole mutation path: the layout verbs, the rules an
  agent's verb answers to (`admit`), one `commit` every change goes through, `bench.json`, and
  booting from it. `src/spawn.rs` is a session plus the pane that shows it; `src/ask.rs` is
  benchd asking helm for what only helm can do (`helm/ask`, `helm/answer`).
- `crates/bench` — the CLI, the one agent-facing surface, and the attach client. `src/verbs.rs`
  is the pane verbs and spawn (M3); `src/attach.rs` is the relay a helm pane runs. Two verbs
  never open the socket: `bench log` reads a transcript file directly, and `bench wiring` prints
  (or `--check`s) the one-time hook wiring for the operator's own agents.
- **benchd runs as a login agent** (`com.wirasm.benchd`, `scripts/benchd-agent.sh`, #407). To
  restart the live one, `launchctl kickstart -k gui/$(id -u)/com.wirasm.benchd`; starting a
  second benchd by hand beside it is refused at the socket and leaves launchd retrying. Tests and
  proofs use a suite or `BENCH_DIR`, never the agent.
- There is deliberately **no root `Cargo.toml`** in the repo: `cargo` at the repo root
  fails loudly instead of half-working.

## Rules

- **Bench-visible means logged.** A mutation appends its event before the response that
  reports it. A new capability is new event kinds + new verbs over the same socket —
  never a second channel (no files-as-IPC, no extra sockets, no notification side paths).
- **Tests never touch the operator's estate.** Claim a disposable `HOME` (or `BENCH_DIR`)
  under the OS tempdir — the OS tempdir specifically: unix socket paths cap near 104
  bytes and long scratch paths fail at bind. Include the negative control: assert the
  shared root shape was never created.
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
  binaries, both directions, every status case (the shape helm's spool conformance suite had).
- Conventional commits, written as a human — no AI attribution (repo rule).
