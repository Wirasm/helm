# Spike: provider, model, and effort are controllable at spawn — and verifiable

**Question**: when the bench spawns an agent, can the caller pick the model and the
reasoning effort per runtime — and can the selection be *verified* rather than trusted?

**Verdict: PROVEN, 7/7 cases.** 2026-08-18. Zero model turns: each case spawns the TUI
into a harness-owned pty with selection flags and reads the chrome — the runtime's own
declaration of what it is running — then kills it. ~5s per case.

| case | flags | chrome showed |
|---|---|---|
| claude sonnet | `--model sonnet` | sonnet ✓ |
| claude opus | `--model opus` | opus ✓ |
| claude opus, effort high | `--model opus --effort high` | opus + high ✓ |
| codex model | `-m gpt-5.3-codex` | 5.3 ✓ |
| codex effort high | `-c model_reasoning_effort=high` | 5.3 + high ✓ |
| pi sonnet | `--model anthropic/claude-sonnet-5` | sonnet ✓ |
| pi opus, thinking high | `--model anthropic/claude-opus-4-5:high` | opus + high ✓ |

## The selection surface, per runtime

- **claude**: `--model <alias|full-id>` + `--effort <level>` — both first-class flags.
- **codex**: `-m/--model <id>` + `-c model_reasoning_effort=<level>` (the generic
  `-c key=value` config override).
- **pi**: `--provider <name>` / `--model <pattern>` supporting `provider/id` **with an
  optional `:<thinking>` suffix**, plus `--thinking off|minimal|low|medium|high|xhigh|max`
  and `--models` for a cycling set. The catalog is `~/.pi/agent/models.json` (+
  `models-store.json`), listed by `pi --list-models`; **which entries are usable is
  decided by `auth.json`** — the authenticated subset the operator cares about, not the
  whole library.

## Design consequences for `bench spawn` (M3)

- The spawn verb carries `{agent, model?, effort?}` and maps them per runtime exactly as
  the posture table already maps permission flags — one more column in the same
  `SpoolUnattendedPolicy`-shaped table, not a new mechanism. Omitted means the runtime's
  own default, never a bench-invented one.
- **Chrome-reading is spike instrumentation, not the product's verification.** benchd
  should record what was *requested* in the spawn event (`agent/spawned` carries model +
  effort) and leave verification to the runtime's own typed channels where they exist —
  never a regex over the pane (posture: capabilities, not parsing).
- pi's authenticated-subset question suggests a later `bench spawn --list` passthrough
  (ask each runtime what it can run) rather than bench maintaining its own catalog —
  the runtimes already own that truth.

Harness: scratchpad `pty-spike/src/bin/model_spike.rs` (throwaway; this file is the
deliverable). Companions: pty-ownership, mail-wake, group-room.
