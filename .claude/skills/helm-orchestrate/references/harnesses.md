# Harnesses and models

What `bench spawn` can start, which harness and model to pick for a job, what each costs, and how
to check a model name before a fleet depends on it. Model names were verified on 2026-10-03
against claude 2.1.288, codex 0.160.0 and pi 0.99.2 (`bench status` names the installed ones).
Flags were verified on 2026-10-01 against `bench_session::argv`
(`daemon/crates/bench-session/src/lib.rs`), the one spelling of every flag benchd passes.
Re-check a name that matters: aliases move, and so does what an account may use.

## Who decides

1. **The operator's word wins.** A harness, model or effort he names is used as named, for as long
   as he said. Record it as a standing decision.
2. **Otherwise use the default** in the table below.
3. **The orchestrator may override a default when it says why**, in the run file's Workstreams
   row after the model: `codex · gpt-6.1-sol · high (claude 7-day window at 90%)`. A reason is
   something about this task or this moment: a limit, a second model family for a review, a round
   that already failed. Never override the operator's word.

## Which harness and model for which job

Always pass `--model` and `--effort`. With neither, each harness falls back to a different
default (Flags below), and none of them is what this table picks.

| Job | Default | Alternatives | Why | Evidence |
|---|---|---|---|---|
| Delivery (`prp-issue`: issue to reviewed PR) | `claude` `opus` `high` | `pi` `openai-codex/gpt-6.1-sol` `medium`; `codex` `gpt-6.1-sol` `high` | Runs the whole PRP chain; the most delivery evidence | E1, E2, E3, E5 |
| Wire format, daemon state, isolation, data loss | `claude` `opus` `high`; `xhigh` after a failed round | `codex` `gpt-6.1-sol` `xhigh`, reviewed by claude | A miss costs the most here. Daemon and wire work in E1 and E6 ran on opus. Two codex implementers on `gpt-5.6-sol` `xhigh` (through Archon) got a wire change right; `gpt-6.1-sol` is untested on wire work | E1, E4 |
| UI: helm views, browser pane | `claude` `opus` `high` | `pi` `openai-codex/gpt-6.1-sol` `medium`; `codex` `gpt-6.1-sol` `high` | All three delivered browser work; a screenshot needs a model that reads images | E5 |
| Spike | `claude` `opus` `high` | `codex` `gpt-6.1-sol` `high`, when an independent model family is the point | Every spike verdict in E1 and E6 came from opus | E1, E6 |
| Review (`prp-review`) | `claude` `opus` `high` | `codex` `gpt-6.1-sol` `high`, for a reviewer from the other model family | Claude reviewed every PR in E2. codex ran `prp-review`'s reviewer fan-out itself on #615 and #619 | E2, E4, E5 |
| A question about an agent's work | `--fork <its runtime>`, its own harness | | Read-only copy; the author is not disturbed | E7 |
| Research: read sources, write a report | `claude` `opus` `high` | `codex` `gpt-6.1-sol` `high` | Opus is the runs' default; no research job has been tried on another model | E1 |
| Hard diagnosis that failed once on opus | `claude` `fable` `xhigh` | `claude` `opus` `max` | Fable 5.1 is Anthropic's most capable model, at 2.5x opus's price. Untested in our runs | E8 |
| Mechanical: rebase, conflict catch-up, doc fix | `claude` `sonnet` `medium` | `codex` `gpt-6-luna` `medium` | A cheaper tier spends a plan window slower. Untested for code here: read the first one's diff | E8 |
| One-shot reply, harness or mail test | `claude` `haiku` `low` | `pi` `minimax/MiniMax-M2.7-highspeed` `low` | Cheapest models that answer; the mail ring defaults to these two | E7, E9 |
| A model only pi reaches, or work on pi itself | `pi` `<provider/id>` | | pi holds the MiniMax and OpenRouter keys | E9 |

Notes the table cannot hold:

- **pi and codex run the same `gpt-6.1-sol` with different results** (pi at medium, codex at
  high). pi stayed in scope and reported its evidence candidly. codex wrote stronger tests but
  deleted 93 comment lines outside its task and called a finding fixed before it was (R1 on #593,
  E2). A codex brief should say: keep
  existing comments, and probe the sibling case before calling a finding closed.
- **pi cannot run a PRP chain** (skills below). Its deliveries worked because the brief spelled out
  plan, gate, red/green proof and PR, and the orchestrator ran the review.
- **MiniMax-M2.7 reads no images** (`pi --list-models`), so it cannot check a screenshot.
  MiniMax-M3 and every claude and gpt model can.
- **Visual acceptance stays the operator's**, whichever model drew the change.

## Cost and plan limits

Read the plan windows before a fleet, and again when one agent stops for a limit:

```bash
bench sessions | python3 -c '
import json, sys, time
now = time.time() * 1000
for u in json.load(sys.stdin)["usage"]:
    for w in u["windows"]:
        print(u["harness"], u.get("account", ""), "%dh window" % (w["minutes"] // 60),
              "%d%% used" % w["used_percent"],
              "read %dm ago" % ((now - w["at_ms"]) / 60000),
              "resets in %dh" % ((w["resets_at_ms"] - now) / 3600000))'
```

Each harness publishes its own reading when it runs a turn, so a window read hours ago may
already have reset. Weigh the age before moving work on it. A second Claude login reports apart,
with `account` set to its config dir; no `account` is the default login.

| Account | Window | Hit so far | Spends it |
|---|---|---|---|
| Claude, two subscriptions | 5 hours and 7 days | 5-hour limits stopped two agents on 2026-09-25; the 7-day limit stopped three agents and four baseline runs on 2026-10-01/02 (E1, E3) | every `claude` spawn |
| Codex, one subscription | 7 days | stopped a delivery until 2026-09-28 (E1) | every `codex` spawn, and `pi` on `openai-codex/*` (pi's own login to the same subscription) |
| MiniMax, OpenRouter | none: API keys, paid per token | | `pi` on `minimax/*` or `openrouter/*` |

- benchd picks the Claude login per spawn, by quota, once the second is set up (README, "A
  second Claude account"); you pick only the model. A resume stays on its conversation's login,
  and goes to the other when that one is spent. A stopped agent is resumed, not replaced: four
  dead baseline runs cost $16.43 (E3).
- When Claude's fullest window is near its limit, put the next deliveries on `gpt-6.1-sol` (pi or
  codex) rather than queue them. The two families do not share a limit.
- API list prices per million tokens in and out (claude-api skill, 2026-09-25): fable $10/$50,
  opus $4/$20, sonnet $2/$10, haiku $1/$5. Expect a fable agent to fill a window faster than an
  opus one; not measured.
- A Claude Code session runs at most 20 subagents at once (E1). That bounds an orchestrator's
  subagent fan-out, not benchd spawns.
- codex reports tokens and no dollar cost, so a codex run is compared in tokens (E4).

## Evidence

Files are in `~/.prp/helm-3ec376fc/`.

- **E1** `orchestration/2026-09-25-bench-chain.md`: every delivery and spike of the run on opus;
  the limit stops; the 20-subagent cap.
- **E2** `reports/codex-pi-trial-review-2026-10-02.md` and `orchestration/2026-10-02-codex-pi-trial.md`:
  codex (#593) and pi (#592) on `gpt-6.1-sol`. Both merged after three review rounds. Scored by a
  claude reviewer: pi at or near Claude parity; codex weaker on scope and on closing findings.
- **E3** `reports/delivery-baseline-2026-10-01.md`: one simple task three ways, all on opus.
  prp-issue $3.59, quick deliver $2.93, archon-ship $6.20, same quality. Only prp-issue caught a
  false comment, by testing it.
- **E4** `reports/delivery-baseline-2-2026-10-01.md`: a wire change across Rust and Swift on codex
  `gpt-5.6-sol`; correct, 23/25 from claude reviewers. archon-review on codex failed on an output
  schema until Archon #3560.
- **E5** `orchestration/2026-10-02-browser-polish.md`, `reports/browser-ime-followup-report.md`
  and `reports/oopif-pickers-report.md`: browser work by claude (#613), codex (#615, #619) and pi
  (#614, #618), each to a READY review and green CI. codex's rollouts for #615 and
  #619 (`~/.codex/sessions/2026/10/02/`) show its review reviewers started with `spawn_agent`.
- **E6** `orchestration/2026-10-02-attention-next.md`: opus spikes (#466 shared codex app-server
  PROVEN, the phone app CONDITIONAL) and deliveries (#620 to #629).
- **E7** `reports/harness-parity-2026-10-01.md`: spawn, mail, restore and read-only fork compared
  across the three harnesses, with haiku and MiniMax as the test agents; forks for codex and pi
  shipped in #575.
- **E8** No run of ours yet. The facts are Anthropic's (claude-api skill). Replace this with a
  run once one exists.
- **E9** `daemon/mail-ring.py` (`DEFAULT_MODELS`) and `pi --list-models`.

## Flags

| | claude | codex | pi |
|---|---|---|---|
| `--model` | alias or full name | model slug | `provider/id` |
| models (2026-10-03) | `opus` → claude-opus-5-5, `sonnet` → claude-sonnet-5-5, `haiku` → claude-haiku-4-5, `fable` → claude-fable-5-1 | `gpt-6.1-sol` (latest workhorse), `gpt-6-astra` (frontier), `gpt-6-sol` (previous workhorse), `gpt-6-luna` (fast); `gpt-5.6-*` is what Archon's codex config runs | `openai-codex/gpt-6.1-sol`, `openai-codex/gpt-6-astra`, `minimax/MiniMax-M3`, `minimax/MiniMax-M2.7-highspeed`, `pi --list-models` for the rest |
| default with no `--model` | the operator's Claude Code setting | `~/.codex/config.toml` (`gpt-6-astra`, medium) | `~/.pi/agent/settings.json` (`openai-codex/gpt-5.6-sol`, a generation old) |
| `--effort` | `low` `medium` `high` `xhigh` `max` | `low` `medium` `high` `xhigh`, plus `max` and `ultra` on some models; set on the thread benchd creates | `off` `minimal` `low` `medium` `high` `xhigh` `max`; appended to the model as `:<level>` |
| `--resume <id>` | yes | yes, by its thread id | yes |
| `--fork <id>` | yes, read-only (plan mode), its own new id | yes, read-only (read-only sandbox), its own new thread | yes, read-only (`--tools read,grep,find,ls`), its own new id |
| posture | `--dangerously-skip-permissions` | full access and approvals `never`, set on the thread; an `--arg` reaches only the TUI | `--approve` |
| mail wake when idle | yes (inbox socket) | yes when benchd spawned it (benchd's codex app-server) | yes (`bench` extension) |
| activity in `bench sessions` | busy, shell, idle, waiting with its own words | busy, idle, waiting, from its thread's events on benchd's app-server | busy, idle, waiting, from its hooks |
| `bench log` | yes | yes | yes |

`runtime_session` in the spawn answer is the id `--resume` and `--fork` take, for codex too:
benchd makes every codex thread on its own codex app-server before the pane starts (#466).
codex is spawned only into a folder the operator trusts. Do not use `/new` in a benchd codex: the
new conversation runs in the wrong folder and benchd does not own it; spawn a new agent instead.

With no `--effort`, claude takes the operator's Claude Code setting and codex the
`model_reasoning_effort` in `~/.codex/config.toml` (`medium`), falling back to the model's own
default (`low` for `gpt-6.1-sol`) only when that key is unset. The table above names an
effort for every job; raise it one level for a round that already failed.

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
as an error in the pane, not as a refused spawn. `gpt-6.1-sol` answered "not supported when using
Codex with a ChatGPT account" on 2026-10-01 and worked from 2026-10-02. The cache
(`~/.codex/models_cache.json`) lists what exists; the check says what this account can use today.
