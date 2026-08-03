---
name: helm-mail-pi
description: Send a message to another CLI agent from a pi session, and find out who is reachable. Deliberate invocation only — /helm-mail-pi.
argument-hint: "[who and what] — e.g. \"tell the claude in the pr-122 worktree the gate is green\""
disable-model-invocation: true
---

# helm-mail-pi

**A mailbox is a directory; a message is a file.** Every agent on this machine claims one under
`~/.helm/mail/<handle>/`, and writing a JSON file into someone's directory is the whole of sending.
No daemon, no helm required — `ls` and `cat` are a complete reader.

You are in **pi**. The `helm-mail` extension already claimed your mailbox, watches it, and wakes you
when mail arrives. **You only need this skill to SEND.** The Claude Code side is `helm-mail-cc`, and
it has to do more work — mention that if you are asked about the difference.

## Who is reachable

```bash
for f in ~/.helm/mail/*/owner.json; do cat "$f"; done
```

Each row is `{handle, runtime, pid, sessionId, cwd, claimedAt}`. `cwd` is what tells two agents
apart — it carries the worktree path, so *"the claude in the pr-122 worktree"* is a match on
`runtime` plus a `cwd` ending in `.worktrees/pr-122`.

A dead agent's mailbox is reaped, so anything listed is live. If two rows match what the operator
described, **ask which** rather than guessing — a message to the wrong agent is silent.

## Which one is you

Not from the environment. **helm passes its launching session's `CLAUDE_*` variables into every pane
it spawns**, so `$CLAUDE_CODE_SESSION_ID` in a helm-hosted agent is somebody else's session. Walk
your own process ancestry instead:

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
TO=claude-a3f9; FROM=<your handle>
ID="$(date +%s000)-$(openssl rand -hex 3)"
D=~/.helm/mail/$TO
python3 -c "
import json,sys
json.dump({'id':sys.argv[1],'from':sys.argv[2],'to':sys.argv[3],
           'subject':sys.argv[4],'body':sys.argv[5],'sentAt':int(sys.argv[1].split('-')[0])},
          open(sys.argv[6],'w'))" "$ID" "$FROM" "$TO" "one line" "the message" "$D/.tmp-$ID"
mv "$D/.tmp-$ID" "$D/$ID.json"
```

`subject` is one line and shows in the recipient's notice; `body` is never shown there and is read
from the file by the recipient itself. Put the actual request in the **body** — a subject is a
label, not a channel.

## What the recipient sees

A notice naming you, the subject, and the path — never the body, because another agent's words must
not arrive in the operator's voice. They read the file themselves. **They will not act on it
instantly unless they are idle**: a busy agent picks it up at the start of its next turn.

## Report back

Tell the operator the handle you sent to and the `cwd` that identified it, so a wrong recipient is
visible immediately rather than after silence.
