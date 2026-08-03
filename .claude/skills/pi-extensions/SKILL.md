---
name: pi-extensions
description: Build, test, install and upgrade pi coding-agent extensions without taking the pi CLI down. Use when the user wants to "write a pi extension", "add a slash command to pi", "register a pi tool", "hook a pi session event", "my pi extension broke", "pi won't start", "test a pi extension", "pi upgraded and my extension stopped working", or invokes /pi-extensions.
---

# pi extensions

Write a pi extension that cannot break pi, can be tested without spending a model call, and
fails visibly rather than silently when pi changes under it.

The worked example is `pi/extensions/helm-probe/` with its harness `scripts/test.sh` — read those
before writing a new one; copying that directory is the intended way to start.

## Before anything else: read the installed pi

pi's extension API is pre-1.0 and moves. Never answer a question about it from memory, from a
blog post, or from this skill alone — **read the copy installed on this machine**, and say which
version was read.

```bash
PI=$(npm root -g)/@earendil-works/pi-coding-agent
node -p "require('$PI/package.json').version"   # say this version in whatever is written
```

Four places hold the truth, in decreasing order of reliability:

| Read | For |
|---|---|
| `$PI/dist/core/extensions/types.d.ts` | the real `ExtensionAPI` — every event name, every method signature |
| `$PI/dist/core/extensions/loader.js` | what actually happens at load: discovery, module aliasing, error handling |
| `$PI/examples/extensions/` | ~70 working examples, one per capability |
| `$PI/docs/extensions.md`, `$PI/docs/rpc.md`, `$PI/CHANGELOG.md` | prose, the RPC frame protocol, and what broke in each release |

The docs are good but lag the code; when prose and `dist/` disagree, `dist/` wins and the
disagreement is worth recording. Details and the upgrade-diff procedure: `references/reading-pi.md`.

## Two kinds, one skeleton

Both are built from `pi/extensions/helm-probe/` and tested by `pi/test.sh`. The difference is
who they are for, and it decides what may go in them.

**Class A — drives helm.** Publishes a session registry row so helm's board lights up for a pi
terminal, emits OSC 9;4 so the tab ring animates, reports pane state. Useless without helm, and
free to depend on it.

**Class B — works in a bare pi TUI.** A HUD showing cost, model, git dirty state, current tool,
turn elapsed. Keybinding and theme helpers. **Must not depend on helm at all** — no helm paths,
no helm env vars, no assumption that a terminal is hosted. Someone running pi with no helm
should be able to install it and have it work.

State which class an extension is in its header. A class B extension that quietly reaches for a
helm path is the failure this distinction exists to prevent.

**When a class B extension is worth publishing on its own, this skill and the skeleton move out
of helm.** That is the extraction trigger — not a second codebase, which would arrive much later.
Until then both classes live here because they share one harness and one test command.

## The one rule

**A factory that throws takes the entire pi CLI down** — `exit 1`, for every directory on the
machine, because `~/.pi/agent/extensions` is discovered everywhere. A *handler* that throws is
contained: pi emits `extension_error` and exits 0.

So the split is absolute:

- **Inside the factory** — nothing may throw. Ever.
- **Below it** — handlers, commands, tools — anything may throw. It costs one `extension_error`.

Write the factory total: whole body in one `try`, every pi method feature-detected before use,
each registration independently guarded. Recipe with code: `references/writing-a-total-factory.md`.

**Inert is not the same as silent.** Degrading is fine; degrading without a trace is the defect.
Every fallback path must reach stderr.

## Building one — design, then build

Two steps, and the first is short. Full runbook: `references/building-an-extension.md`.

**Step 1 — design, and get it agreed before writing anything.** State in a few lines: which pi
surface the job needs and why, what it registers, and what proves it works. The surface is the
expensive decision and the cheapest to change now:

| Surface | Reach for it when | Costs |
|---|---|---|
| **command** (`registerCommand`) | a person invokes it deliberately | free — no model turn, RPC-testable |
| **tool** (`registerTool`) | the *model* should decide when to use it | a turn, plus context for its schema |
| **event handler** (`pi.on`) | it must react whether or not anyone asked | runs every session; a bad one is felt everywhere |
| **UI** (`ctx.ui.*`) | the session should show something | interactive-only; degrade when there is no UI |
| **provider** (`registerProvider`) | a new model backend | rare; read the examples first |

Default to a command. A tool that could have been a command spends a turn for nothing, and an
event handler that could have been a command runs forever for a job someone asked for once.

**Step 2 — build, in this order.** The order carries the safety:

1. **Copy** `pi/extensions/helm-probe/` and `pi/tests/helm-probe.mjs`, rename in all four places.
2. **Read** the installed pi for the exact API being used — signature, event name, return shape.
3. **Write** the factory total (`references/writing-a-total-factory.md`).
4. **Write the tests alongside it**, including the mutilated-pi cases. Not after — after is how
   the mutilation cases get skipped and a false green ships.
5. **Loop the gate until green.** Not a self-assessment: `scripts/test.sh` exits nonzero.
6. **Install last**, and only once green.

Installing before green is the one genuinely dangerous step. A symlink into
`~/.pi/agent/extensions` puts the extension in *every* pi session on the machine, so a factory
that still throws stops pi starting everywhere. Test against an explicit path until it passes:

```bash
pi --no-extensions -e "$PWD/pi/extensions/<name>/index.ts"     # isolated, ignores what is installed
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/<name>" ~/.pi/agent/extensions/<name>  # only when green
```

`/reload` re-runs the factories on an edited file, so iterating does not need a session restart.
Do not hold a captured `ctx` across it.

## Test without a model

```bash
bash .claude/skills/pi-extensions/scripts/test.sh [typecheck|unit|rpc|pty|all]
```

| Harness | Proves |
|---|---|
| `typecheck` | an API in use has changed. **The upgrade alarm.** |
| `unit` | the factory survives a deliberately mutilated pi. Milliseconds, no pi process. |
| `rpc` | it loads under the real loader, and its UI calls surface as frames |
| `pty` | a real interactive pi still reaches a prompt with it loaded |

Two facts make no-model testing possible: `session_start` fires at startup with no prompt, and
an extension command invoked over RPC as a `/`-prefixed prompt is handled locally. How each
harness works, and how to add one: `references/testing.md`.

The script operates on the project it is **run from**, not on the skill directory it lives in, so
it works unchanged in any repo with extensions under `pi/extensions/`. `PI_EXT_DIR` overrides
that layout.

## Surviving an upgrade

Optimise for breaking **visibly and inertly**, not for never breaking — reacting fast beats
pinning.

The trap that forces the design: subscribing to an event pi no longer has **succeeds silently**.
`pi.on()` only pushes into a map, so the handler never fires and nothing is logged. Runtime will
never tell. Two things catch it and both are needed — the **typecheck**, which names the event,
and a **behavioural assertion** in the suite, which notices the effect went missing.

That is why an extension imports the real `ExtensionAPI` type instead of duck-typing the surface.
Duck-typing keeps the build green through exactly the upgrade worth hearing about. Run the
typecheck against the installed pi, never a vendored copy of its types.

## Gotchas

Four things that behave the opposite of how they read. Each is stated with the command that
demonstrates it in `references/measured-traps.md` — read that before debugging any of them.

- **`pi.getFlag()` in a factory returns the registered default, never the value on argv.** A
  flag-based kill switch reads correctly and does nothing; use an environment variable.
- **A vendored `typebox` is ignored** — pi aliases the specifier to its own bundled copy.
- **Action methods throw during load** (`sendMessage`, `exec`, `setModel`, …). At factory time,
  only *register*.
- **Old package names still resolve** (`@sinclair/typebox`, `@mariozechner/pi-*`) but name
  packages that are not what runs. Import `typebox` and `@earendil-works/…`.

## Resources

- `references/building-an-extension.md` — the two-step runbook: choosing a surface, then the build order
- `references/reading-pi.md` — where each answer lives in the installed package, how to verify a claim, how to diff an upgrade
- `references/writing-a-total-factory.md` — the safety recipe, with the code
- `references/measured-traps.md` — surprising behaviour, each with the command that shows it
- `references/testing.md` — the four harnesses, why none needs a model, how to add one
- `scripts/test.sh` — the gate. Run it, don't read it; it operates on the project it is run from
