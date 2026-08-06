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

o = json.load(open(sys.argv[1]))
print("retired" if o.get("retiredAt") else "live" if alive(o.get("pid")) else "dead", json.dumps(o))
PY
done
```

`find` here for the reason spelled out at length under *Arm*, below: under zsh a glob matching
nothing is fatal, and `~/.helm/mail/*/owner.json` matches nothing on a machine where no agent has
claimed a mailbox yet. Printing no rows is the right answer to "who is reachable" when nobody is.

One line per mailbox — its state, then the whole of its `owner.json`:

```
live {"handle": "agentic-coding-course-c9db", "runtime": "claude", "pid": 68658, ...}
retired {"handle": "helm-4831", ..., "claimedAt": 1786028945735, "retiredAt": 1786045284085}
dead {"handle": "helm-7139", "runtime": "claude", "pid": 54430, ...}
```

Each row is `{handle, runtime, pid, sessionId, cwd, claimedAt}`, plus a `retiredAt` once the
mailbox has been retired. `cwd` is what tells two agents apart — it carries the worktree path, so
*"the pi in the pr-122 worktree"* is a match on `runtime` plus a `cwd` ending in
`.worktrees/pr-122`.

**Listed is not the same as live, and `retiredAt` is asked before the pid.** When any agent starts
a session it reaps the mailboxes whose owners are gone, and reaping **rewrites `owner.json` with a
`retiredAt` rather than deleting the directory** (#236). The directory and its `read/` stay on
purpose: a retired mailbox is still worth reading, it is only not worth writing to. **A row
carrying `retiredAt` is not a recipient** — the send succeeds, the file lands, and nobody ever
opens it.

**The pid cannot tell you that, which is why it is asked second.** A retired owner's pid may still
be alive — the `/clear` ghost's is, and the kernel reuses pids — so `kill -0` calls a mailbox
nobody is listening to perfectly healthy. Measured against a mailbox the real hook had just
retired: `kill -0` said live, and the row said `retired` (#248). This section used to teach the
`kill -0` on its own, which is the wrong test the moment a mailbox can be retired instead of
deleted.

**The pid check stays, because it catches what `retiredAt` has not caught yet.** Reaping only runs
when some agent starts a session, so an idle machine keeps its corpses unmarked; and a mailbox
still holding unread mail is left unretired deliberately, because that mail is evidence and the
handle may be re-claimed. `dead` is a real state, and for the purposes of sending it means what
`retired` means.

**A live pid is not proof of a live agent.** If two rows share one pid, the one whose `sessionId`
matches `~/.claude/sessions/<pid>.json` is the real agent and the other is a `/clear` ghost — the
process is alive, it just runs somebody else now. The next session start retires it, so this is a
window rather than a permanent state, but sending into it during that window is silent.

Mail to a `retired` or `dead` handle goes nowhere and says nothing. If the one you want is not
`live`, tell the operator rather than sending into it — and say which of the two it was, because
`retired` means that agent existed and is gone where `dead` may only mean nobody has reaped it yet.

There is no separate one-handle check. The listing *is* the check, and each row is one line, so
`… | grep <handle>` is how you ask about one.

If two live rows match what the operator described, **ask which** rather than guessing — a message
to the wrong agent is equally silent.

## Which one is you

A handle is `<basename of your cwd>-<tail of your session id>` — the last **4** characters of the
id when that is free, widened to 6, then 8, then the whole id when a live process already holds the
shorter form (`deriveHandle`, `hooks/helm-mail.mjs`). Widening is **rare** — every mailbox claimed
on this machine so far resolved at 4, four of them agents sharing one directory — and rare is what
makes computing the name the wrong move rather than a safe one. The width is not fixed, nothing
tells you which one you got, and a derivation that is right in every test anyone writes is wrong
the first time two session ids happen to end in the same four characters. `HELM_MAIL_HANDLE`
short-circuits the derivation entirely as well, so a pinned session's handle need not look like
this at all.

**Which is the reason to read `owner.json` rather than compute anything: a session id does not
yield a handle.** Knowing exactly which session you are still leaves the name of your mailbox as
something only the claim on disk can tell you.

`$CLAUDE_CODE_SESSION_ID` is a red herring rather than a trap, and it is worth saying which.
Measured inside a helm pane, it is **your own** session: Claude Code sets it for the processes it
spawns, overriding whatever the pane's shell was carrying. It simply does not name a mailbox.
Where helm's leak bites is everywhere Claude Code is not there to overwrite it — a **pi** pane,
which sets no `CLAUDE_*` of its own and so read the launching session's outright; the pane's bare
shell before any agent starts; the subprocesses helm runs itself. **helm strips them now (#139)**,
and a helm built before that fix still hands all three the launcher's identity.

helm does publish one thing, and it is not this: **`$HELM_PANE`** is the uuid of the pane you are
running in (#94). It names the pane, which outlives you — several agents run in one pane over its
life — so it is not a handle and not a session id.

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
mv "$D/.tmp-$ID" "$D/$ID.json" || echo "SEND FAILED — $D is gone; the message was NOT delivered"
```

Put the actual request in the **body** — `subject` is a one-line label shown in the recipient's
notice, and the body is what they read from the file.

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

**The `mv` cannot catch a retired mailbox, and that is the failure it most looks like.** A retired
directory is still there — that is the whole point of retiring rather than deleting — so the rename
succeeds, the `||` stays quiet, and the message is never read. There is nowhere later to catch it:
`retiredAt` is checked in the listing, before you compose. pi's extension refuses a retired
recipient in code; writing the file yourself is what this runtime does instead, so the check is
yours to make.

## Arm — the part only this runtime needs

Mail delivered by the hook arrives **at the start of your next turn**. If nobody prompts you, you
never see it. Nothing outside a Claude Code session can start a turn in one — but a watch **you**
arm can, because being notified *is* the wake.

Arm a background watch on your own mailbox, one notification per message:

```bash
BOX=~/.helm/mail/<your handle>
while true; do
  find "$BOX" -maxdepth 1 -name '*.json' ! -name 'owner.json' -type f 2>/dev/null | while read -r f; do
    echo "MAIL $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['from'])" "$f") — $f"
    mkdir -p "$BOX/read" && mv "$f" "$BOX/read/"
  done
  sleep 2
done
```

**`find`, not a glob, and do not simplify it back to one.** Under **zsh** a pattern matching
nothing is a *fatal error* — `no matches found: …/*.json` — not an empty list, so
`for f in "$BOX"/*.json` does not iterate zero times: it kills the shell the watch runs in, on the
first pass, before the loop body executes once. You then go dark, and **you cannot notice that from
inside a turn you are not having**. Claude Code's own Bash tool runs `/bin/zsh`, so this is the
shell your watch actually gets.

This loop was a glob for months, guarded by `case "$f" in *owner.json|*'*.json')`. That second
pattern is **bash** — bash leaves an unmatched glob in place as literal text, and the `case` catches
it — so the empty mailbox looks defended and, under zsh, is not: the body is never reached to run
the guard. Read in bash it is correct, which is exactly why it survived and why this paragraph is
here (#237).

An empty box is not exotic — it is every moment after you have read your mail. When this was
written it was worse than that: reaping **deleted** the mailbox, so not even `owner.json` was an
entry that always matched, and the two defects compounded — the directory went away and the watch
that would have reported it died in the same instant. Reaping retires now and the directory stays
(#236), so that particular pair cannot recur, and `owner.json` is there throughout.

`find` returns nothing and exits 0 in either dialect, and keeps doing so on a directory deleted
outright — but **surviving is not the same as receiving**. A watch on a mailbox that has been
retired out from under you stays alive and perfectly silent, because a retired box is one nobody
will write to again. Silence is not evidence that nothing was sent; if it goes on, run the listing
above and look at your own row.

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
