# Spike: can a headless daemon own the pty under a full interactive agent TUI?

**Question** (bench-roadmap invariant 3, the design's riskiest bet): can a process with no
window and no controlling terminal — what benchd will be — own a pty hosting a full
interactive agent, deliver a prompt paste-then-submit, and get real work back?

**Verdict: PROVEN, for all three runtimes.** 2026-08-18, throwaway Rust harness
(`portable-pty` 0.9), spawned from a Claude Code tool call (tty `??`, no controlling
terminal — the headless condition, not a simulation of it). Postures were helm's
`SpoolUnattendedPolicy` verbatim; prompt delivered as paste, then `\r` separately
(helm's launch-line rule); the required reply was **computed** (`6*7` → `BENCH-42-DONE`)
so the echo of our own typed bytes could not fake a pass.

| runtime | posture flag | TUI drew | interactive | computed reply | resize mid-session |
|---|---|---|---|---|---|
| claude 2.1.234 | `--dangerously-skip-permissions` | yes | 3.9s | 10.0s | survived |
| codex 0.147.0 | `--dangerously-bypass-approvals-and-sandbox` | yes | 4.9s | 9.3s | survived |
| pi 0.83.0 | `--approve` | yes | 3.3s | 8.1s | survived |

Notes with design weight:

- **The pty owner's first duty is draining the master.** The harness reads continuously
  on a thread; an undrained master blocks the agent on write. benchd's session loop must
  never stop reading, whatever the attach state is.
- **Marker matching needed ANSI stripping and whitespace-tolerant search** — replies
  arrive interleaved with redraw sequences. The attach protocol should ship grid state,
  not raw byte scrollback, which is what the roadmap already says (M5).
- **codex's posture flag**: helm documents `-p yolo` (a profile); the spike used the
  explicit `--dangerously-bypass-approvals-and-sandbox`, which worked on 0.147.0. The
  M3 posture table should record both spellings and pick one.

**Not proven here, still owed to M5**: the attach protocol itself (grid snapshot +
diffs, keys up), long-lived survival (hours, sleep/wake), reboot resume (typing
`--resume` into a fresh pty), and backpressure behavior when a reader stalls. The core
bet those all sit on — full TUIs run correctly under a headless pty owner — is the thing
this spike retires.

Harness source: scratchpad `pty-spike/` (throwaway, session-local; this file is the
deliverable).
