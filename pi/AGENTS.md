# AGENTS.md — pi extensions

TypeScript extensions for the **pi sessions helm hosts**, in whatever repo the user is in — not
for agents working on helm. That is why they are symlinked into `~/.pi/agent/extensions/` and not
kept in helm's own `.pi/extensions/`, which would load them only inside this checkout.

**The craft lives in the `pi-extensions` skill, not here.** How to write a factory that cannot
take pi down, how to read the installed pi rather than guess at its API, the measured traps, and
how the harnesses work — all of it is in `.claude/skills/pi-extensions/`. Read that before
writing or changing an extension. This file is orientation and the gate; it deliberately does not
restate any of it.

## Layout

```
extensions/<name>/index.ts    the extension
extensions/<name>/README.md   what it is, and how to install it
tests/<name>.mjs              its unit harness, found by name
test.sh                       the gate
```

`extensions/helm-probe/` is the reference implementation — copy that directory to start a new
one. The directory name is load-bearing: it is also the test filename, the command the extension
registers, and the first word it reports, and `test.sh` finds all four by it.

Only directories go under `extensions/`. A stray `.ts` at that level would be discovered as its
own extension.

## The gate

```bash
bash .claude/skills/pi-extensions/scripts/test.sh
```

**Run this when you touch `pi/`. It is separate from helm's Swift gate on purpose** — that one
needs only the Swift toolchain and xcodegen, while this needs node and a `tsc` from `npm install`
in this directory. Coupling them would make every Swift contributor install a JS toolchain to
make the repo go green.

Nothing in it calls a model, so it is free to run.

## Provenance

Everything the skill states about pi was measured against **pi 0.83.0 on 2026-08-02**, except one
claim — that `/reload` picks up an edited extension without a session restart, which the operator
verified by hand because the automation cannot watch a live TUI. Keep that distinction when
adding to either file: what a command proved and what someone reported are not the same kind of
fact, and a reader deserves to know which one they are getting.
