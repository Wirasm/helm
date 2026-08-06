# helm-mail

One agent leaves another a message. A message is a file; a mailbox is a directory.

This is the pi half of [#55](https://github.com/Wirasm/helm/issues/55) (rung 3), with the address
space [#77](https://github.com/Wirasm/helm/issues/77) called for. There is no daemon, no engine
and no helm in the path — `ls` and `cat` are a complete reader, which is the property #55 asks
for: *"works with no helm running at all."*

## The finding worth reading first

**For pi, rungs 3 and 4 are the same file.** [#56](https://github.com/Wirasm/helm/issues/56)
exists because an idle Claude Code session cannot be woken by a file appearing — only a `Stop`
hook exiting 2 can, running in the background so the turn genuinely ends, and
`~/.claude/hooks/kild-rewake.sh` has to park in an 8-hour loop because a session that goes idle
unarmed stays dark until a human speaks.

pi needs none of it. Measured on 0.83.0: `agent_settled` fires *"after an agent run has fully
settled and no automatic retry, compaction, or queued continuation will run"*, and
`dist/core/agent-session.js:315` clears `_isAgentRunActive` **before** awaiting extension
handlers. So a handler on that event is genuinely between turns, `ctx.isIdle()` is true inside
it, and `pi.sendUserMessage()` starts a clean turn. No lock file, no park, no rearm hole.

That is the strongest evidence yet for #77's *"pi's side is strictly better and differently
shaped."*

## The address

`<basename of cwd>-<last 4 of the session id>` — `helm-a3f9`, `kild-2b7c`. Derived rather than
negotiated, because many instances of one agent run at once, in separate worktrees and sometimes
in the same directory, and a claim race is a bug you only meet when two of them start together.

**The LAST four, and that word is the whole of [#126](https://github.com/Wirasm/helm/issues/126).**
This first said *first* four and called the result unique *by construction*; both were wrong, and
in the same way. pi session ids are UUIDv7 — the leading 48 bits are a millisecond clock — so the
first four hex characters advance about once every 50 days, and every pi session started this
month derived the same `019f`. Two live sessions in helm, measured: `sild-019f` and `kild-019f`.
Three concurrent sessions in *one* directory got one mailbox between them, which is precisely the
race the paragraph above says this avoids.

The tail sits in the random half, so 4 characters is 16 real bits. That is unique with **high
probability**, not by construction — so the claim also looks: if the handle is already held by a
**live** process, it takes 6 characters, then 8, then the whole id. A dead owner's handle is free,
so a widened handle is temporary rather than a permanent scar on the address space.

Handles are folded to lower case. That is not cosmetic: on a case-insensitive filesystem — the
macOS default — `Alice` and `alice` are two agents to a sender and one directory to the disk, so
the second claim silently takes the first one's mail. kild hit this and documented it.

A sender cannot guess a handle, which is correct: you list who is alive and address one, the way
a person would. `owner.json` carries the cwd, so *"the one in the auth worktree"* is a lookup.

```
~/.helm/mail/                        ($HELM_MAIL_DIR overrides the root)
  helm-a3f9/
    owner.json                       {handle, runtime, pid, sessionId, cwd, claimedAt}
                                     plus retiredAt once its owner is gone
    1785753688503-9f2a1c.json        a waiting message
    read/
      1785753612001-3ab77e.json      consumed, kept as the record
```

**A dead agent's empty mailbox is retired** on the next claim, and on its own way out. A mailbox
that only grows is the defect helm already paid for twice
([#46](https://github.com/Wirasm/helm/issues/46)'s 1,514 leaked domains,
[#91](https://github.com/Wirasm/helm/issues/91)'s 17 terminal ids against 2 live shells) — and a
dead agent must stop being *addressable*, or a sender picks it out of a listing and nobody ever
reads the message. Reaping is conservative: a mailbox still holding mail is left live even when its
owner is dead, and an owner file that cannot be read is left alone.

**Retired, never deleted** — [#236](https://github.com/Wirasm/helm/issues/236). `retiredAt` is
written into `owner.json` and the directory stays where it is. Deleting cost three things the goal
never asked for: `read/`, which is the only durable record of what agents said to each other; an
in-flight send, because a sender's `.tmp-<id>` does not count as queued mail and the directory
could vanish mid-write; and the difference between *"this agent existed and is gone"* and *"this
handle never existed"*, which is exactly what a sender holding an old handle needs told apart.
`/helm-mail list` marks a retired mailbox `[retired]`, and a send to one is refused with a reason.

A retired mailbox costs **no** handle width — it is free to take, like any dead owner's. And a
session that comes back re-claims its own, archive intact, because a mailbox is found by session
id rather than by pid.

**Liveness is decided from the session, not from the pid.** `owner.json` records a pid when the
session starts and is never rewritten, so a helm restart brings every agent back under a *new* pid
and leaves a corpse in every owner file. For a `runtime: "claude"` mailbox the answer is Claude
Code's own registry — `<config>/sessions/<pid>.json` — which this extension reads even though pi
has no such registry of its own, because pi's reaper sweeps the shared root and judges Claude
Code's mailboxes too. Reading the pid alone deleted a running agent's mailbox on 2026-08-06.

## Sending from a Claude Code agent

No CLI is needed and none is provided. The convention is the interface — write the file:

```jsonc
// ~/.helm/mail/<their-handle>/<millis>-<6 hex>.json
{ "id": "1785753688503-9f2a1c", "from": "my-handle", "to": "their-handle",
  "subject": "one line", "body": "the message", "sentAt": 1785753688503 }
```

Write to a temp name in the same directory and `rename` it in, so a reader listing mid-write sees
nothing rather than half a message.

**Nothing here is trusted, and it used not to be true.** This path never passes through the
extension's own `send()`, which is where `subject` was being sanitized — so a subject with
newlines in it forged whole lines of the recipient's notice, carrying this extension's prefix and
an approval nobody gave ([#127](https://github.com/Wirasm/helm/issues/127)). The guard now sits in
`notice()`, the one place every sender converges: `from` and `subject` are each collapsed to one
bounded line there, and the path is taken from the **file on disk** rather than from the `id`
field, which a sender is free to disagree with.

A Claude Code agent **reading** its own mailbox is [#56](https://github.com/Wirasm/helm/issues/56)
and is not built here.

## What it registers

| Surface | Name | Notes |
|---|---|---|
| Event handler | `session_start` | Claims the handle, retires dead mailboxes, reports. |
| Event handler | `agent_settled` | The drain. This is rung 4 for pi. |
| Command | `/helm-mail` | `status` · `list` · `read` · `send <handle> <message>` |

No tool. The model should not decide when to check mail — a tool would spend a turn and its
schema's context on a job that must happen whether or not anyone asked.

Each registration is feature-detected and installed independently: a pi that has lost one still
gets the others and says on stderr which went missing.

## Two rules carried over from kild, which already paid for them

**Notify, not deliver.** The notice names the sender, a bounded one-line subject, and the path.
It never carries the body. The body is another agent's words, and a `sendUserMessage` carrying it
would put those words in the operator's voice — indistinguishable, at the point of reading, from
an instruction the human typed. [#29](https://github.com/Wirasm/helm/issues/29) measured what
that costs when prose landed in a live permission prompt and its `y` approved a network command.
The agent reads the file with its own tools, where it lands as a file.

**A wake cap of 3.** Waking a session spends the owner's money, and two agents replying to each
other wake each other until it runs out. At the cap the extension goes quiet and says so on
stderr; the mail is **not** eaten, and the next drain reports it. Any drain that finds nothing
resets the counter, so a real conversation is never permanently capped.

Delivery is idle-only. pi's `deliverAs: "steer" | "followUp"` would let a message reach an agent
mid-turn, and it is deliberately not used: it reopens the guard question #29 could not answer,
and the sender would have to know the recipient's runtime. Add it when something needs it.

## Install

```bash
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/helm-mail" ~/.pi/agent/extensions/helm-mail
```

A symlink, so editing in the repo is what ships. Remove the symlink to uninstall.

**This puts it in every pi session on the machine**, which is the point — an agent is only
addressable if it claims a mailbox on start.

## Switch it off without uninstalling

```bash
HELM_MAIL_OFF=1 pi
```

An environment variable rather than a CLI flag: measured on 0.83.0, `pi.getFlag()` inside a
factory returns the flag's registered *default*, never the value on argv, so a flag-based kill
switch would read correctly and do nothing.

## Run it in isolation

```bash
pi --no-extensions -e "$(git rev-parse --show-toplevel)/pi/extensions/helm-mail/index.ts"
```

`HELM_MAIL_DIR=/tmp/somewhere` points the whole convention elsewhere, which is what makes the
test suite hermetic — no run touches the real mailbox.

## Test it

```bash
bash .claude/skills/pi-extensions/scripts/test.sh          # typecheck, unit, rpc, pty — none calls a model
```
