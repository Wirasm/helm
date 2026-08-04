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

**A live pid is not proof of a live agent.** If two rows share one pid, the one whose `sessionId`
matches `~/.claude/sessions/<pid>.json` is the real agent and the other is a `/clear` ghost — the
process is alive, it just runs somebody else now. The next session start reaps it, so this is a
window rather than a permanent state, but sending into it during that window is silent.

Mail to a dead handle goes nowhere and says nothing. If the one you want is dead, tell the operator
rather than sending into it.

If two live rows match what the operator described, **ask which** rather than guessing — a message
to the wrong agent is equally silent.

## Which one is you

A handle is `<basename of your cwd>-<last 4 of your session id>`, so two agents in one directory
differ only in the suffix — which makes guessing from the name alone a coin flip.

Not from the environment either. **helm passes its launching session's `CLAUDE_*` variables into
every pane it spawns**, so `$CLAUDE_CODE_SESSION_ID` is very often somebody else's session —
measured, not theoretical.

Walk your ancestry to your own Claude Code process, ask the runtime which session is in it, then
match that against the mailboxes:

```bash
p=$$; while [ "$p" -gt 1 ] && [ ! -f ~/.claude/sessions/$p.json ]; do
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
done
python3 - "$p" <<'PY'
import glob, json, os, sys
me = json.load(open(os.path.expanduser("~/.claude/sessions/%s.json" % sys.argv[1])))["sessionId"]
for f in glob.glob(os.path.expanduser("~/.helm/mail/*/owner.json")):
    o = json.load(open(f))
    if o.get("sessionId") == me:
        print(o["handle"]); break
PY
```

**Match on the session id, not on the pid** — that is the whole point of the extra step.
`~/.claude/sessions/<pid>.json` is Claude Code stating which session is in that process *now*, and
it is rewritten in place when a session restarts. Two mailboxes can name one live pid: `/clear` starts
a fresh session in the same process, claims a fresh handle, and abandons the old one. Grepping
`owner.json` for your pid returns **both**, with nothing to choose between them — that happened, and
the older box is a ghost that `kill -0` still calls live. The session id has one answer.

If it prints nothing, no mailbox is yours yet — a session started before the hooks were wired. Say
so rather than adopting the closest-looking handle.

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

Run it with the **Monitor** tool, which turns each line into a notification. Monitor is a deferred
tool, so load it first — otherwise the call fails and it looks like the watch is the problem:

```
ToolSearch  { "query": "select:Monitor", "max_results": 1 }
Monitor     { "command": <the loop above>, "persistent": true }
```

**`persistent: true` and no `timeout_ms`.** Persistent means it runs until you stop it or the
session ends, which is exactly the lifetime you want; a timeout alongside it is at best ignored and
at worst the hour your watch quietly dies. Do not invent a number — two agents doing this on the
same day picked 5 minutes and 1 hour, neither meaning to be dark after it.

It dies with your session, which is right; there is nothing to clean up.

**Re-arm whenever it ends.** A watch that stops leaves you dark, and you cannot notice that from
inside a turn you are not having.

The message it moves into `read/` is yours to open with `Read` — the watcher deliberately prints the
sender and the path, never the body, because another agent's words must not reach you looking like
the operator's.

**Once armed, the watch replaces the hook — including the hook's instructions.** It polls every two
seconds and the hook only runs when the operator prompts you, so the watch takes every message
first and the hook's notice stops appearing. That notice is where the reply convention and this very
advice are written, so from then on **this file is your only copy**: to answer anything the watch
hands you, use *Sending* above.

## Report back

Tell the operator the handle you sent to and the `cwd` that identified it, so a wrong recipient is
visible immediately rather than after silence. If you armed a watch, say so — it is otherwise
invisible.
