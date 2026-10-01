# Harnesses and models

What `bench spawn` can start, what each harness is good for, and how to check a model name before
a fleet depends on it. Facts here were verified on 2026-10-01 against claude 2.1.286, codex
0.157.0, pi 0.84.4 and `bench_session::argv` (`daemon/crates/bench-session/src/lib.rs`), which is
the one spelling of every flag benchd passes. Re-check a name that matters: aliases move.

## Which harness for which job

- **claude** runs the PRP chain end to end. The prp-core plugin skills are installed for it, its
  Agent tool gives `prp-review` the reviewers it fans out to, and benchd's hooks give it mail and a
  live activity state. Every delivery in the 2026-09-25 run was claude on opus. Use it for
  `prp-issue`, `prp-plan`, `prp-review`, and anything that touches wire formats, daemon state,
  focus, isolation or possible data loss.
- **codex** is the other model family. Use it for a spike or a second review where an independent
  model is the point, or to spread load when claude is near its usage limit (both have hit limits
  mid-run). It can run prp skills (`~/.codex/skills` links them), but whether `prp-review`'s
  reviewer fan-out works under codex is unverified, so give it single-agent jobs. It reports no
  activity state and has no `bench log`; read its pane.
- **pi** reaches models the other two cannot (minimax, openrouter) and is how pi itself gets
  tested. It sees no prp skills and no bench skills unless the brief names their files. Give it
  bounded tasks with the instructions in the brief.

Usage limits are a real constraint. A codex weekly limit and claude session limits each stopped
agents mid-work in September. A stopped agent is resumed after the reset (`bench restore <pane>`
or a mail), not replaced.

## Flags

| | claude | codex | pi |
|---|---|---|---|
| `--model` | alias or full name | model slug | `provider/id` |
| models (2026-10-01) | `opus` → claude-opus-5-5, `sonnet` → claude-sonnet-5-5, `haiku` → claude-haiku-4-5, `fable` → claude-fable-5-1 | `gpt-6-astra` (frontier), `gpt-6-sol` (workhorse), `gpt-6-luna` (fast); not `gpt-6.1-sol` on this account | `openai-codex/gpt-6-astra`, `openai-codex/gpt-6-luna`, `minimax/MiniMax-M3`, `pi --list-models` for the rest |
| default with no `--model` | the operator's Claude Code setting | `~/.codex/config.toml` (`gpt-6-astra`, medium) | `~/.pi/agent/settings.json` (`openai-codex/gpt-5.6-sol`) |
| `--effort` | `low` `medium` `high` `xhigh` `max` | `low` `medium` `high` `xhigh`, plus `max` and `ultra` on some models; sent as `-c model_reasoning_effort=` | `off` `minimal` `low` `medium` `high` `xhigh` `max`; appended to the model as `:<level>` |
| `--resume <id>` | yes | no, benchd refuses: codex names its session after the fact | yes |
| `--fork <id>` | yes, read-only (plan mode), its own new id | no | no |
| posture | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--approve` |
| mail wake when idle | yes (inbox socket) | yes when benchd spawned it (its app-server) | yes (`bench` extension) |
| activity in `bench sessions` | busy, shell, idle, waiting with its own words | unknown | unknown |
| `bench log` | yes | no | yes |

`runtime_session` in the spawn answer is the id `--resume` and `--fork` take. It is null for codex.

Effort is a judgment, not a table: `high` for delivery, `xhigh` or `max` for a hard design or a
diagnosis that has already failed once, `medium` or `low` for mechanical work.

## Which skills each harness can see

| | prp skills | helm's bench skills (`bench-*`, `helm-canvas`) |
|---|---|---|
| claude | yes, as `prp-core:<name>` | yes inside the helm repo (`.claude/skills`); elsewhere only `helm-canvas` (linked from `~/.claude/skills`) |
| codex | yes (`~/.codex/skills`), mentioned as `$<name>` | `helm-canvas` only |
| pi | no | `helm-canvas` only (from `~/.claude/skills`, which pi's settings list) |

When an agent cannot see a skill, the brief names the file:
`/Users/rasmus/Projects/mine/sild/helm/.claude/skills/bench-mail/SKILL.md`, or
`/Users/rasmus/Projects/mine/sild/prp/plugins/prp-core/skills/<name>/SKILL.md`. A prp skill that
composes other prp skills by name (`prp-issue` runs `prp-plan`, `prp-implement`, `prp-review`) does
not work that way in pi; do not give pi a PRP chain.

To check what a harness sees now: `ls ~/.codex/skills`, and the `skills` array in
`~/.pi/agent/settings.json` plus `~/.agents/skills`.

## Verify a model name

Each check costs one short turn. Run it before spawning more than one agent on a name.

```text
claude -p --model <alias> --output-format json "reply ok" | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["modelUsage"]))'
codex exec --skip-git-repo-check -m <slug> "reply ok" </dev/null 2>&1 | tail -3
pi -p --model <provider/id> "reply ok"
```

codex accepts any name at start and fails at the first turn, so a wrong name in a spawn shows up
as an error in the pane, not as a refused spawn. On 2026-10-01 `gpt-6.1-sol` was listed in
`~/.codex/models_cache.json` and still answered "not supported when using Codex with a ChatGPT
account". The cache lists what exists; the check says what this account can use.
