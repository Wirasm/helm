---
name: bench-mail
description: Send and receive mail between agents on the bench (benchd). Use when a "You have mail" notice appears in your session, when you have been told your bench address, when you need to message another agent or the operator, or when you need to find out who you can mail.
---

# bench mail

Mail between agents hosted by `benchd`. This is the capability surface — what the
mailroom does, mechanically. What to say, when to reply, and how to structure a
conversation are yours.

**Your address** comes to you when your session starts: a line saying
`You are <handle> on the bench`. A session benchd spawned also has it as `$BENCH_HANDLE`. An
agent in a helm pane gets one the first time its harness reports to benchd (see *Wiring*).
Every command below finds the right bench by itself. The `bench` CLI is on your PATH or named
by `$BENCH`.

## Receiving

Mail reaches you as one line, never typed into your terminal:

```text
You have mail from <sender>: <path>
```

The path IS the message — a markdown file with `from:`/`at:`/`subject:` front-matter and
the body below it. `cat` it. It is moved to your `read/` directory the moment the notice is
handed to you, so the path in the notice is where it lives.

Facts with edges:

- **The notice never contains the body.** Reading the file is how you get the message.
- **Busy, you get it at your next tool call or prompt**, as hook context. A permission
  prompt or a question you asked holds it until the next tool call after it.
- **Idle, a turn is started for you** with the notice, through your harness's own
  channel: a Claude session's inbox socket, or pi's `bench` extension. Those turns are
  **capped**: burst of 6 per recipient, refilling one per minute. codex has no such channel
  yet and gets its mail at its next prompt or tool call instead.
- Held or capped mail waits **unread in your inbox**. Nothing is lost; `bench mail list`
  shows what accumulated.
- Nothing else wakes you. No polling loop exists to arm.

## Who can I mail

`bench sessions --all` is the list of agents in your workspace, and each row says whether
it has a mailbox here. There is no separate directory.

```bash
BENCH="${BENCH:-bench}"
OUT=$($BENCH sessions --all) || exit
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
o = d["operator"]
print(o["handle"], "unread=%d" % o["unread"])
for r in d["rows"]:
    m = r["mail"]
    if m:
        print(m["handle"], "wakeable" if m["wakeable"] else "not-wakeable",
              "unread=%d" % m["unread"], r["harness"], r.get("name") or r["id"])
'
```

- The workspace is your cwd's repo and all its worktrees. `--workspace <dir>` asks about
  another one.
- `operator` is a top-level field, not a row. It is always addressable and never
  wakeable: the operator reads mail when they choose to.
- `mail` on a row is `null` when the session has no benchd mailbox: it is not hosted by
  helm or benchd, or its harness is not wired to `bench hook` yet.
- `wakeable: true` means benchd can start a turn for that agent when it is idle, so a send
  answers `"wake": "queued"`. `false` means the mail waits for the agent's next prompt or
  tool call (`"wake": "next-turn"`).
- `unread` is how much mail already waits in that inbox.

## Sending

```bash
BENCH="${BENCH:-bench}"
$BENCH mail send --to operator --subject demo --body "one line is fine"
```

- `--body <text>` or `--body-file <path>` (multi-line goes by file).
- **Sign with `--from <your handle>`.** It defaults to `$BENCH_HANDLE`, which only a session
  benchd spawned has; without either, a send is signed `operator`.
- `operator` is always addressable and belongs to the operator.
- A recipient benchd cannot start a turn for is not woken; the response says
  `"wake": "next-turn"` and the mail waits in their box.

## Listing and reading

```bash
BENCH="${BENCH:-bench}"
$BENCH mail list --handle operator
```

Metadata only — id, sender, subject, time, read-state — bodies never, caps reported.

```bash
BENCH="${BENCH:-bench}"
OUT=$($BENCH mail list --handle operator) || exit
ID=$(printf '%s' "$OUT" | python3 -c "import json,sys; m=json.load(sys.stdin)['mail']; print(m[0]['id'] if m else '')")
[ -z "$ID" ] || $BENCH mail read "$ID" --handle operator
```

The `|| exit` keeps bench's exit code (2 no daemon, 3 refused). Without it, a listing that
failed would look like an empty inbox.

`read` returns the body and retires the message (inbox → `read/`). Nothing in the
mailroom ever deletes; the files under `$BENCH_DIR/mail/<handle>/` are the record and
plain `cat` reads them.

## Wiring (once per machine, by the operator)

A session benchd spawns reports to benchd on its own. An agent the operator starts himself —
Claude Code, codex or pi in a helm pane — reports only once its harness is wired to the one
fixed command, `bench hook <harness>`. The installed `bench` prints exactly what to add:

```bash
BENCH="${BENCH:-bench}"
$BENCH wiring
```

- **Claude Code:** merge `claude.merge` into `~/.claude/settings.json`: one handler on each
  event, plus `crossSessionInbound: "accept"` so benchd can start a turn in an idle session.
  Without that setting, a push is held behind a dialog in the pane and the mail waits for the
  next prompt.
- **codex:** merge `codex.merge` into `~/.codex/hooks.json`, then trust the hook once in
  codex's `/hooks`. The command never changes, so it is trusted once.
- **pi:** link `pi/extensions/bench` from a helm checkout into `~/.pi/agent/extensions/`.

`bench wiring --check` reads the files and says what is missing (exit 3 until all of it is
there). Nothing here writes to the operator's files: the wiring is his to add.

## Exit codes

`0` ok · `2` no daemon · `3` refused (the reason names the rule) · `4` daemon failed.
