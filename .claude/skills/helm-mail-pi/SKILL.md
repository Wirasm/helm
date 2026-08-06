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

**Listed is not the same as live — check the pid.** A dead agent's mailbox is usually reaped, but
not always: one still holding unread mail is kept deliberately (that mail is evidence, and the
handle may be re-claimed), and reaping only runs when some agent starts a session, so an idle
machine keeps its corpses.

```bash
kill -0 <pid> 2>/dev/null && echo live || echo DEAD
```

**A live pid is not proof of a live agent, on the Claude side.** If two `claude` rows share one pid,
the one whose `sessionId` matches `~/.claude/sessions/<pid>.json` is the real agent and the other is
a `/clear` ghost — that session ended, but the process it ran in did not. The next Claude session
start reaps it; sending into it before that is silent. pi has no equivalent, so a pi row with a live
pid is a live agent.

Mail to a dead handle goes nowhere and says nothing. If the one you want is dead, tell the operator
rather than sending into it.

If two live rows match what the operator described, **ask which** rather than guessing — a message
to the wrong agent is equally silent.

## Which one is you

**Not from the environment, because a session id does not yield a handle.** `deriveHandle` takes
the last 4 characters of the id, widens to 6, 8 and then the whole thing when a live process holds
the shorter form, and skips all of it when `HELM_MAIL_HANDLE` is pinned — so no amount of correct
identity tells you your mailbox name. Only the claim on disk does.

The environment is also where **you** are the case that got bitten. helm passed its launching
session's variables into every pane it spawned, and a pi overwrites none of the `CLAUDE_*` ones —
which is how a pi in a pane came to print `CLAUDECODE=1` next to `PI_CODING_AGENT=true`, and why
anything asking *"am I inside Claude Code?"* got a yes. **helm strips them now (#139)**; a helm
built before that fix still hands them to you. `$HELM_PANE` is the one thing helm publishes (#94):
the uuid of the pane, which outlives any one agent in it, so it is not a handle either. Walk your
own process ancestry:

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
mv "$D/.tmp-$ID" "$D/$ID.json" || echo "SEND FAILED — $D is gone; the message was NOT delivered"
```

`subject` is one line and shows in the recipient's notice; `body` is never shown there and is read
from the file by the recipient itself. Put the actual request in the **body** — a subject is a
label, not a channel.

**Check the `mv`, and mean it.** A mailbox is a directory, so a send whose target directory is gone
writes nothing — the box was reaped while you composed (#236), or the handle was never right. Both
paths do fail loudly *somewhere*: `python3` raises `FileNotFoundError` and `mv` says
`No such file or directory`. Neither is on stdout, and neither says what it cost, so in a long tool
result they read as noise from a block that otherwise looks like it ran. The `||` is what makes the
one thing that matters unmissable. **A failure here means the message was not delivered** — tell the
operator that rather than reporting it sent, and re-read `~/.helm/mail/*/owner.json` to see whether
that handle still exists at all before trying again.

## What the recipient sees

A notice naming you, the subject, and the path — never the body, because another agent's words must
not arrive in the operator's voice. They read the file themselves. **They will not act on it
instantly unless they are idle**: a busy agent picks it up at the start of its next turn.

## Report back

Tell the operator the handle you sent to and the `cwd` that identified it, so a wrong recipient is
visible immediately rather than after silence.
