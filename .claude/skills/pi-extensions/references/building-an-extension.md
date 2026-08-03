# Building an extension

Two steps. Step 1 is a paragraph and a checkpoint; step 2 is the build, and its order carries the
safety.

---

## Step 1 — Design, and agree it before writing

Produce a short design and get it confirmed. Not a document — a few lines answering four
questions. The point is that the expensive decision is made while it still costs a sentence to
change.

1. **What should happen, in one sentence, from the operator's point of view?**
2. **Which pi surface does that need, and why not the cheaper one?**
3. **What does it register** — names, and for a tool, its parameters?
4. **What will prove it works** without a model call?

### Choosing the surface

This is the decision worth slowing down for. Getting it wrong is not a bug — it works, and
quietly costs something forever.

| Surface | Reach for it when | Real cost |
|---|---|---|
| **command** — `registerCommand` | a person invokes it deliberately | none. No model turn; invocable and assertable over RPC |
| **tool** — `registerTool` | the *model* must decide when to use it | a turn each call, plus its schema sits in context every turn |
| **event handler** — `pi.on` | it must react whether or not anyone asked | runs in every session forever; a slow or noisy one is felt everywhere |
| **UI** — `ctx.ui.*` | the session should display something | interactive only — must degrade when there is no UI |
| **provider** — `registerProvider` | adding a model backend | rare, and its own subject; read `examples/extensions/custom-provider-*` first |

Rules of thumb:

- **Default to a command.** It is the cheapest thing that can work, and the easiest to test.
- A **tool** is only right when the model should choose the moment. If a person decides when it
  runs, a tool spends a turn to do a command's job — and its schema taxes every turn besides.
- An **event handler** is right for reacting to the session itself (start, compaction, a tool
  call to intercept). It is the wrong home for a job someone asks for occasionally: it will run
  in every session on the machine, forever, for that one occasion.
- These compose. A command that a tool can also trigger is a normal shape; register both and
  have them call the same function.

### The checkpoint

Say the design back in a few lines and get agreement before writing code. It is cheap here and
expensive after the tests exist.

---

## Step 2 — Build, in this order

The order is not stylistic. Each step exists because doing it later has cost someone something.

### 1. Copy, do not author

```bash
cp -R pi/extensions/helm-probe pi/extensions/<name>
cp pi/tests/helm-probe.mjs pi/tests/<name>.mjs
```

Rename in all four places — the directory, the test filename, the registered command, and the
first word it reports — plus the `*_OFF` environment variable. The harness finds extensions by
name; keeping them in step is what lets a new one be covered with no edit to the gate.

Copying carries the safety structure with it. Authoring from a blank file is how a factory ends
up without its `try`.

### 2. Read the installed pi for the API in play

Before writing the call, read its real signature — `references/reading-pi.md` says where each
answer lives. Check `examples/extensions/` for the capability; there is usually one already.

Do not write from memory of a similar API. The surface is pre-1.0 and the failure mode for a
guessed event name is silence, not an error.

### 3. Write the factory total

Follow `references/writing-a-total-factory.md`: one `try` around the whole body, feature-detect
before calling, guard each registration separately, never call an action method during load, and
never degrade without reaching stderr.

### 4. Write the tests alongside the code, not after

Adapt the copied `tests/<name>.mjs` as the extension takes shape. The mutilated-pi cases are the
ones that get skipped when tests are left to the end, and they are the ones that matter — they
are the only proof the factory cannot take pi down.

Assert that output **arrives**, not merely that nothing threw. "Does not throw" is the assertion
that passes while a handler silently drops everything it was meant to report.

### 5. Loop the gate until green

```bash
bash .claude/skills/pi-extensions/scripts/test.sh
```

An external exit code, not a self-assessment. Fix and re-run until it exits 0. If a harness
prints `skip:`, read why — a skipped typecheck means the upgrade alarm did not run.

While iterating, run against an explicit path so the machine's installed extensions stay out of
it:

```bash
pi --no-extensions -e "$PWD/pi/extensions/<name>/index.ts"
```

### 6. Install last, and only once green

```bash
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/<name>" ~/.pi/agent/extensions/<name>
```

This is the genuinely dangerous step, and the reason it is last. The symlink puts the extension
into **every** pi session on the machine. A factory that still throws stops pi starting in every
directory — including work with nothing to do with this extension.

Never install to "try it out". `-e` is how it gets tried.

To undo: delete the symlink. To silence without uninstalling: the `*_OFF` environment variable.

### 7. Write the README

One short `pi/extensions/<name>/README.md`: what it registers, how to install, how to switch it
off. The copied one is already the right shape.

---

## When it will not load

In order:

1. **pi does not start at all, in any directory** — a factory is throwing. `pi -ne` gets a
   session back; then `pi --no-extensions -e <path>` to find which one.
2. **pi starts but the extension does nothing** — check it is discovered (its name appears in the
   startup `[Extensions]` list), then that the factory ran (put something on stderr), then that
   the handler is firing. A subscription to an event that does not exist is silent; the
   typecheck names it.
3. **It worked before an upgrade** — `CHANGELOG.md` first, then the typecheck, then the suite.
   `references/reading-pi.md` has the order and why.
