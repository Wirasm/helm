---
name: bench-mail
description: Send and receive mail between agents on the bench (benchd). Use when you have a BENCH_HANDLE, when a "You have mail" notice appears in your session, or when you need to message another bench agent or the operator.
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
the body below it. `cat` it. It is already retired (moved to your `read/` directory), so
the path in the notice stays valid.

Facts with edges:

- **The notice never contains the body.** Reading the file is how you get the message.
- **Wakes are delivered only while your pty is idle** (quiet ≥2s), and they are
  **capped**: burst of 6 per recipient, refilling one per minute. Capped or undeliverable
  mail waits **unread in your inbox** — nothing is lost, but nothing further will nudge
  you. `bench mail list` is how you find what accumulated.
- Nothing else wakes you. No polling loop exists to arm.

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
ID=$($BENCH mail list --handle operator | python3 -c "import json,sys; m=json.load(sys.stdin)['mail']; print(m[0]['id'] if m else '')")
[ -n "$ID" ] && $BENCH mail read "$ID" --handle operator
```

`read` returns the body and retires the message (inbox → `read/`). Nothing in the
mailroom ever deletes; the files under `$BENCH_DIR/mail/<handle>/` are the record and
plain `cat` reads them.

## Exit codes

`0` ok · `2` no daemon · `3` refused (the reason names the rule) · `4` daemon failed.
