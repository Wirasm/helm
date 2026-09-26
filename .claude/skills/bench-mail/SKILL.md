---
name: bench-mail
description: Send and receive mail between agents on the bench (benchd). Use when you have a BENCH_HANDLE, when a "You have mail" notice appears in your session, when you need to message another bench agent or the operator, or when you need to find out who you can mail.
---

# bench mail

Mail between agents hosted by `benchd`. This is the capability surface — what the
mailroom does, mechanically. What to say, when to reply, and how to structure a
conversation are yours.

**Your address is `$BENCH_HANDLE`**, set by the daemon that spawned you. If it is
unset, you are not a bench session; you can still send and list as `operator`.
`$BENCH_DIR` (also set for you) is the record root; every command below resolves it
automatically. The `bench` CLI is on your PATH or named by `$BENCH`.

## Receiving

A wake is one line, pasted into your session by the daemon:

```text
You have mail from <sender>: <path>
```

The path IS the message — a markdown file with `from:`/`at:`/`subject:` front-matter and
the body below it. `cat` it. It is moved to your `read/` directory the moment the notice is
delivered, so the path in the notice is where it lives.

Facts with edges:

- **The notice never contains the body.** Reading the file is how you get the message.
- **Wakes are delivered only while your pty is idle** (quiet ≥2s), and a Claude session
  only while its own registry says it can take a turn: `idle`, or `waiting` with nothing
  pending. A permission prompt or dialog holds the wake, because a paste would answer it.
  They are also **capped**: burst of 6 per recipient, refilling one per minute. Held,
  capped or undeliverable mail waits **unread in your inbox** — nothing is lost, but
  nothing further will nudge you. `bench mail list` is how you find what accumulated.
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
- `mail` on a row is `null` when the session has no benchd mailbox. **Today that is every
  agent in a helm pane**: those use helm's older mailroom (`~/.helm/mail`) until #358, and
  `bench mail` cannot reach them.
- `wakeable: true` means benchd hosts that session live, so a send answers
  `"wake": "queued"` and a notice follows (idle-gated and capped, as above). `false`
  means the mail waits in their inbox and nothing nudges them.
- `unread` is how much mail already waits in that inbox.

## Sending

```bash
BENCH="${BENCH:-bench}"
$BENCH mail send --to operator --subject demo --body "one line is fine"
```

- `--body <text>` or `--body-file <path>` (multi-line goes by file).
- Your identity is `$BENCH_HANDLE` automatically; `--from` overrides.
- `operator` is always addressable and belongs to the operator.
- A recipient the daemon does not host is not woken; the response says
  `"wake": "no-live-session"` and the mail waits in their box.

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

## Exit codes

`0` ok · `2` no daemon · `3` refused (the reason names the rule) · `4` daemon failed.
