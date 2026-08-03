---
name: helm-mail-cc
description: Send a message to another CLI agent from a Claude Code session, arm your own mailbox so you can be woken, and find out who is reachable. Deliberate invocation only — /helm-mail-cc.
argument-hint: "[who and what] — e.g. \"tell the pi in the sild worktree hello\", or \"arm\""
disable-model-invocation: true
---

# helm-mail-cc

**A mailbox is a directory; a message is a file.** Every agent on this machine claims one under
`~/.helm/mail/<handle>/`, and writing a JSON file into someone's directory is the whole of sending.
No daemon, no helm required — `ls` and `cat` are a complete reader.

You are in **Claude Code**. A `SessionStart` hook already claimed your mailbox and a
`UserPromptSubmit` hook delivers waiting mail at the start of each of your turns. **The one thing
nobody can do for you is wake you** — see *Arm*, below. pi's side is `helm-mail-pi`.

## Who is reachable

```bash
for f in ~/.helm/mail/*/owner.json; do cat "$f"; done
```

Each row is `{handle, runtime, pid, sessionId, cwd, claimedAt}`. `cwd` is what tells two agents
apart — it carries the worktree path, so *"the pi in the pr-122 worktree"* is a match on `runtime`
plus a `cwd` ending in `.worktrees/pr-122`.

**Listed is not the same as live — check the pid.** A dead agent's mailbox is usually reaped, but
not always: one still holding unread mail is kept deliberately (that mail is evidence, and the
handle may be re-claimed), and reaping only runs when some agent starts a session, so an idle
machine keeps its corpses.

```bash
kill -0 <pid> 2>/dev/null && echo live || echo DEAD
```

Mail to a dead handle goes nowhere and says nothing. If the one you want is dead, tell the operator
rather than sending into it.

If two live rows match what the operator described, **ask which** rather than guessing — a message
to the wrong agent is equally silent.

## Which one is you

Not from the environment. **helm passes its launching session's `CLAUDE_*` variables into every pane
it spawns**, so `$CLAUDE_CODE_SESSION_ID` is very often somebody else's session — measured, not
theoretical. Walk your own process ancestry instead:

```bash
p=$$; while [ "$p" -gt 1 ]; do
  grep -l "\"pid\": $p," ~/.helm/mail/*/owner.json 2>/dev/null && break
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
done
```

The `owner.json` that names an ancestor of your shell is yours; its `handle` is what goes in `from`.

## Sending

Write to a temp name in the same directory and rename it in, so a reader listing mid-write sees
nothing rather than half a message:

```bash
TO=sild-611a; FROM=<your handle>
ID="$(date +%s000)-$(openssl rand -hex 3)"
D=~/.helm/mail/$TO
python3 -c "
import json,sys
json.dump({'id':sys.argv[1],'from':sys.argv[2],'to':sys.argv[3],
           'subject':sys.argv[4],'body':sys.argv[5],'sentAt':int(sys.argv[1].split('-')[0])},
          open(sys.argv[6],'w'))" "$ID" "$FROM" "$TO" "one line" "the message" "$D/.tmp-$ID"
mv "$D/.tmp-$ID" "$D/$ID.json"
```

Put the actual request in the **body** — `subject` is a one-line label shown in the recipient's
notice, and the body is what they read from the file.

## Arm — the part only this runtime needs

Mail delivered by the hook arrives **at the start of your next turn**. If nobody prompts you, you
never see it. Nothing outside a Claude Code session can start a turn in one — but a watch **you**
arm can, because being notified *is* the wake.

Arm a background watch on your own mailbox, one notification per message:

```bash
BOX=~/.helm/mail/<your handle>
while true; do
  for f in "$BOX"/*.json; do
    case "$f" in *owner.json|*'*.json') continue ;; esac
    [ -f "$f" ] || continue
    echo "MAIL $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['from'])" "$f") — $f"
    mkdir -p "$BOX/read" && mv "$f" "$BOX/read/"
  done
  sleep 2
done
```

Run it with whatever gives you a notification per line — in Claude Code that is the **Monitor** tool
with `persistent: true`. It dies with your session, which is right; there is nothing to clean up.

**Re-arm whenever it ends.** A watch that stops leaves you dark, and you cannot notice that from
inside a turn you are not having.

The message it moves into `read/` is yours to open with `Read` — the watcher deliberately prints the
sender and the path, never the body, because another agent's words must not reach you looking like
the operator's.

## Report back

Tell the operator the handle you sent to and the `cwd` that identified it, so a wrong recipient is
visible immediately rather than after silence. If you armed a watch, say so — it is otherwise
invisible.
