# Spike: resume, fork, and rewind — re-entering session state from outside

**Question**: the bench's recovery story (reboot resume, benchd restart as a
resume-storm) and its branching story assume the runtimes can re-enter and branch
session state from a fresh pty. Per runtime: RESUME (kill the pty, come back, context
intact), FORK (branch; the original stays), REWIND (attach to an older point).

**Verdict: resume and fork PROVEN on all three runtimes; rewind PARTIAL (claude only,
UI proven drivable, programmatic selection needs a grid).** 2026-08-18, pty harness,
anti-echo probes (`CODEWORD=`/`FORKED=`/`ROLLED=` wrappers, since a resumed TUI redraws
old conversation into the grid and a bare match would pass on scrollback).

| runtime | resume | fork | rewind-to-point |
|---|---|---|---|
| claude 2.1.234 | ✓ `--resume <uuid>` (id minted at spawn via `--session-id`) | ✓ `--resume <uuid> --fork-session` | `/rewind` UI opens headless; blind selection landed on newest — needs grid-aware navigation |
| codex 0.147.0 | ✓ `codex resume <uuid>` | ✓ `codex fork <uuid>` — native | not surfaced via CLI |
| pi 0.83.0 | ✓ `-c` (continue in cwd) | ✓ `--fork <session-file>` — native | not surfaced via CLI |

## Findings with design weight

- **SIGKILL races the transcript write.** Killing a TUI immediately after its reply
  reached the grid lost the session's last turn on every runtime until a 2–3s grace was
  added. benchd's resume-storm and any pane close must give the child a drain-then-die
  window, not a bare kill.
- **A settle heuristic is not a ready signal.** Resumed TUIs draw in bursts while
  loading history; pasting on "quiet for 2s" intermittently landed before the composer
  existed. The fix was a *content* ready-gate (claude's footer text). The general
  lesson is the pty spike's again: benchd should key actions off grid state, which is
  M5's layer.
- **Session identity should be minted by the spawner.** `claude --session-id <uuid>`
  and pi's `--session-id` let benchd *choose* the id at spawn — no discovery, no
  newest-file race. codex names its own; selection must be anchored to content or a
  recorded id, never to recency (a recency pick during this spike grabbed the
  operator's live codex session and forked it — harmless by fork semantics, but the
  lesson is permanent: **record the id at spawn, never infer it later**).
- Rewind: the capability exists interactively in claude (checkpoint list renders fine
  headless); driving it blind is guesswork. Either wait for M5's grid layer or use
  fork-from-id as the practical "older state" tool — fork is proven everywhere.

## The socket question (not re-run, and deliberately)

helm #320 already measured the Claude socket end to end: idle wake 0.12s (default) /
1.01s (bypass + `crossSessionInbound: "accept"`), the bypass-without-setting case
**silently holds** with a modal nobody sees, platform dedup coalesces only identical
messages (a real ping-pong is never identical), the hook cannot distinguish a wake
from typing (so a cap in a hook counts nothing), and the wire format is unpublished —
the debug-line `{"type":"user","message":{...}}` shape. Its recommendation lands
exactly where benchd already stands: **the courier owns the wake and the cap**,
poke-as-doorbell if used at all, file mailbox canonical. For the bench: the pty wake
is proven, runtime-neutral, and ours; the socket buys ~a second of latency on one
runtime at the price of an unpublished format plus a settings precondition. Not
load-bearing — revisit only if idle-gating proves costly in practice.

Harness: scratchpad `pty-spike/src/bin/session_spike.rs` (throwaway). Companions:
pty-ownership, mail-wake, group-room, model-selection; helm #320 for the socket.
