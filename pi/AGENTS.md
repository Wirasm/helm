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

**If you touched `extensions/helm-mail/`, that gate is not enough — also run:**

```bash
bash hooks/test.sh
```

`helm-mail` is one convention written three times: this extension, `hooks/helm-mail.mjs` for
Claude Code, and `Sources/HelmWire/Spool/Handle.swift` for the handles helm reads back. The two
JavaScript halves **reap each other's mailboxes** — pi's reaper sweeps the shared root and judges
Claude Code's owners, and the hook does the same in reverse — so a divergence between them is one
runtime destroying the other runtime's agents, which is what #236 was. `hooks/mailbox-conformance
.mjs` (#246) lifts the rules out of all three sources and executes them against one fixture set;
`hooks/test.sh` is where it runs, and its header argues that home. It needs node >= 22.18 and
nothing else — it reads this extension's `.ts` by type stripping, with no build step, so it does
not need pi's `npm install` at all. **22.18 and not 22.6**, which is what this line and three
others used to say: 22.6 is where `--experimental-strip-types` was *added*, and the harness passes
no flags, so what it needs is the version where stripping is on by *default*. Measured — v22.6.0
gives `process.features.typescript === undefined`, v22.18.0 gives `"strip"` — and measured in CI
first, where the pin was `22.6` and the job was red on every branch.

**It is hermetic, and it now proves that rather than claiming it.** Two harnesses start a real pi,
which loads a real extension, which writes real files — helm-mail claims a mailbox, and the gate
used to claim it in the operator's own `~/.helm/mail`, where live agents address each other
(#133). Every root helm's conventions honour is redirected to a per-run temp directory once,
before any harness runs, and the run then fails loudly if the real root gained anything. **Adding
a harness needs no thought about this; adding a root override does** — see the sandbox block in
`scripts/test.sh` and `references/testing.md`.

## Provenance

Everything the skill states about pi was measured against **pi 0.83.0 on 2026-08-02**, except one
claim — that `/reload` picks up an edited extension without a session restart, which the operator
verified by hand because the automation cannot watch a live TUI. Keep that distinction when
adding to either file: what a command proved and what someone reported are not the same kind of
fact, and a reader deserves to know which one they are getting.
