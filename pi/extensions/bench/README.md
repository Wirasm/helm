# bench

pi's sensor for benchd (#358): the pi half of what `bench hook claude` is for Claude Code.

Every event that says what the agent is doing goes to benchd through `bench hook pi`, and
benchd's reply carries the agent's mail as pointer lines (`You have mail from <sender>: <path>`):

- **busy**: at the next model request, through `context`;
- **idle**: a watch on the inbox benchd names asks for the mail, and `sendUserMessage` starts a
  turn with it, when benchd sees the agent idle and its wake cap allows.

The standing rule benchd gives goes into the system prompt of every run. The mailbox, the
address and the cap are benchd's; this holds none of them. With no `bench` on `PATH` (or at
`$BENCH`), or no daemon, it says nothing and pi works as before.

## Install

```bash
ln -s "$PWD/pi/extensions/bench" ~/.pi/agent/extensions/bench
```

Then `/reload` in a running pi, or start a new one. `/bench` says whether the session has a
bench mailbox and its address.

## Test

```bash
bash .claude/skills/pi-extensions/scripts/test.sh
```
