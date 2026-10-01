---
name: bench-sessions
description: Find the agent sessions in a workspace and read what any of them did. Use when you need to know which agents are running or finished, what another agent (or the operator's own session) did or said, why an agent stopped, or before mailing an agent to ask what it did.
---

# bench sessions and bench log

Two commands. `bench sessions --all` says who is and was working in a workspace.
`bench log <id>` says what one of them did. You do not need to mail an agent to find out
what it did; read its log.

The `bench` CLI is on your PATH or named by `$BENCH`.

## Who is working here

```bash
BENCH="${BENCH:-bench}"
OUT=$($BENCH sessions --all) || exit
printf '%s' "$OUT" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["rows"]:
    print(r["harness"], r["id"], r.get("branch") or "", r["state"]["kind"], r.get("name") or "")
'
```

- The workspace is your cwd's repo and all its worktrees. `--workspace <dir>` asks about
  another one.
- Rows cover agents in helm panes, benchd sessions, Claude `--bg` jobs, running subagents,
  and finished sessions helm or benchd hosted. Running rows come first.
- `branch` is the short branch checked out in the row's worktree (`feat/x`), or `null` when
  the root is not a git checkout, its HEAD is detached or HEAD cannot be read.
- It needs benchd running (exit 2 when it is not). The `bench-mail` skill covers each row's
  `mail` field.
- **`name` is the harness's own**: Claude's session name, codex's thread name, pi's `/name`.
  A codex row's `id` is the thread it runs now: after `/new` it is the new thread.
  `bench sessions` (without `--all`) and `bench mail who` give the same id as
  `runtime_session` and `session`.
- **A running row whose agent waits on the operator** says `"activity": {"kind": "waiting",
  "waiting_for": "permission prompt"}` (or `trust prompt`, `question`, …): the agent's own
  report, or a prompt benchd read off its screen, which is how a codex or pi prompt, or a Claude
  trust prompt, shows up at all. `bench sessions` (without `--all`) gives each benchd session's
  `waiting` with `since_ms` and its `source`, `hook` or `screen`.

## What did it do

```bash
BENCH="${BENCH:-bench}"
$BENCH log "$SESSION" -n 20
```

`$SESSION` is a row's `id`. `bench log` prints the conversation's tail, oldest first: `user`
for a prompt, `agent` for a text reply, `tool` for a tool call (its name and a short
argument), and `error` for a failed tool call or an API error. Tool results and thinking are
left out. Times are UTC. In this text form a long entry is cut at 12 lines.

For the full text, read the JSON:

```bash
BENCH="${BENCH:-bench}"
OUT=$($BENCH log "$SESSION" -n 20 --json) || exit
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["harness"], d["path"], "%d of %d" % (d["returned"], d["total"]))
for e in d["entries"]:
    print(e["at"], e["kind"], e.get("tool") or "", e["text"].splitlines()[0] if e["text"] else "")
'
```

Facts with edges:

- **It reads the transcript file directly** and needs no daemon. It also takes a transcript
  path instead of an id, such as a subagent row's `open.path`.
- **`--since` takes `30m`, `2h`, `1d` or an RFC 3339 time**, and `-n` then keeps the last N of
  those (40 by default). `total` counts the entries after `--since`.
- **Claude, pi and codex.** A codex row's `id` is its thread id, and its log is read from the
  rollout's typed items, so injected context (AGENTS.md, environment, hook context) is left
  out. A message from another codex agent shows as `user`; its payload is encrypted.
- **A record it does not recognise is skipped, never guessed at.** Each one is printed on
  stderr as `bench: <path>:<line>: skipped, <why>` and listed in `unreadable` in the JSON.
  A non-empty `unreadable` means the harness changed its format; say so rather than
  trusting the log to be complete.
- It shows what the agent did, not what it will do next. For "is it blocked right now", the
  row's `state` in `bench sessions --all` is the answer.

## Exit codes

`0` ok · `2` no daemon (`sessions` only) · `3` refused: an unknown id or a bad flag · `4` the
file could not be read, or a pi session or codex rollout in a format this build does not read.
