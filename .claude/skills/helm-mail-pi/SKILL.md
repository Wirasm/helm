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
find ~/.helm/mail -maxdepth 2 -name owner.json -type f 2>/dev/null | while read -r f; do
  python3 - "$f" <<'PY'
import json, os, sys

def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)          # signal 0 asks whether it exists; it kills nothing
    except PermissionError:
        return True              # another user owns it, so it is there
    except OSError:
        return False
    return True

try:
    o = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable", sys.argv[1])   # half-written or hand-edited; say so, do not vanish
    sys.exit(0)
print("retired" if o.get("retiredAt") else "live" if alive(o.get("pid")) else "dead", json.dumps(o))
PY
done
```

`find`, not `for f in ~/.helm/mail/*/owner.json`: under **zsh** a glob matching nothing is a fatal
error rather than an empty list, and that pattern matches nothing on a machine where no agent has
claimed a mailbox yet. Printing no rows is the right answer to "who is reachable" when nobody is —
a dead shell is not (#237).

One line per mailbox — its state, then the whole of its `owner.json`:

```
live {"handle": "agentic-coding-course-c9db", "runtime": "claude", "pid": 68658, ...}
retired {"handle": "helm-4831", ..., "claimedAt": 1786028945735, "retiredAt": 1786045284085}
dead {"handle": "helm-7139", "runtime": "claude", "pid": 54430, ...}
```

A fourth state, `unreadable <path>`, is an `owner.json` that would not parse — half-written, or
edited by hand. It is a row rather than a traceback on purpose: one broken mailbox must not take
the eight beside it out of the answer, and it must not vanish from it either. pi's `/helm-mail
list` says `no owner.json` about the same file.

Each row is `{handle, runtime, pid, sessionId, cwd, claimedAt}`, plus a `retiredAt` once the
mailbox has been retired. `cwd` is what tells two agents apart — it carries the worktree path, so
*"the claude in the pr-122 worktree"* is a match on `runtime` plus a `cwd` ending in
`.worktrees/pr-122`.

**Listed is not the same as live, and `retiredAt` is asked before the pid.** When any agent starts
a session it reaps the mailboxes whose owners are gone, and reaping **rewrites `owner.json` with a
`retiredAt` rather than deleting the directory** (#236). The directory and its `read/` stay on
purpose: a retired mailbox is still worth reading, it is only not worth writing to. **A row
carrying `retiredAt` is not a recipient** — the file you write lands, and nobody ever opens it.

**The pid cannot tell you that, which is why it is asked second.** A retired owner's pid may still
be alive — the `/clear` ghost's is, and the kernel reuses pids — so `kill -0` calls a mailbox
nobody is listening to perfectly healthy. Measured against a mailbox the real hook had just
retired: `kill -0` said live, and the row said `retired` (#248). This section used to teach the
`kill -0` on its own, which is the wrong test the moment a mailbox can be retired instead of
deleted. `/helm-mail list` marks the same rows `[retired]`, for the same reason and from the same
field.

**The pid check stays, because it catches what `retiredAt` has not caught yet.** Reaping only runs
when some agent starts a session, so an idle machine keeps its corpses unmarked; and a mailbox
still holding unread mail is left unretired deliberately, because that mail is evidence and the
handle may be re-claimed. `dead` is a real state, and for the purposes of sending it means what
`retired` means.

**A live pid is not proof of a live agent, on the Claude side.** If two `claude` rows share one pid,
the one whose `sessionId` matches `~/.claude/sessions/<pid>.json` is the real agent and the other is
a `/clear` ghost — that session ended, but the process it ran in did not. The next Claude session
start retires it; sending into it before that is silent. pi has no equivalent, so a pi row with a
live pid and no `retiredAt` is a live agent.

Mail to a `retired` or `dead` handle goes nowhere and says nothing. If the one you want is not
`live`, tell the operator rather than sending into it — and say which of the two it was, because
`retired` means that agent existed and is gone where `dead` may only mean nobody has reaped it yet.

There is no separate one-handle check. The listing *is* the check, and each row is one line, so
`… | grep <handle>` is how you ask about one.

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
writes nothing — the handle was never right, or somebody removed the directory by hand. (Reaping is
no longer one of the ways: it retires the mailbox and leaves it where it is — see the paragraph
after this one, which is the case the `||` cannot see.) Both paths do fail loudly *somewhere*:
`python3` raises `FileNotFoundError` and `mv` says
`No such file or directory`. Neither is on stdout, and neither says what it cost, so in a long tool
result they read as noise from a block that otherwise looks like it ran. The `||` is what makes the
one thing that matters unmissable. **A failure here means the message was not delivered** — tell the
operator that rather than reporting it sent, and re-read the listing above to see whether that
handle still exists at all before trying again.

**The `mv` cannot catch a retired mailbox, and this snippet is not `/helm-mail send`.** The
extension's `send()` refuses a retired recipient with a reason; this block writes the file itself,
so nothing refuses on your behalf — the rename succeeds into a retired directory, the `||` stays
quiet, and the message is never read. Check `retiredAt` in the listing, before you compose.
`/helm-mail send <handle> <message>` does carry the guard — it just puts your one string in both
`subject` and `body`, which is why the block above exists at all.

## What the recipient sees

A notice naming you, the subject, and the path — never the body, because another agent's words must
not arrive in the operator's voice. They read the file themselves. **They will not act on it
instantly unless they are idle**: a busy agent picks it up at the start of its next turn.

## Report back

Tell the operator the handle you sent to and the `cwd` that identified it, so a wrong recipient is
visible immediately rather than after silence.
