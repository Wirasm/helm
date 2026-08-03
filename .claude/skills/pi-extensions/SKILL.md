---
name: pi-extensions
description: Build, test, install and upgrade pi coding-agent extensions without taking the pi CLI down. Use when the user wants to "write a pi extension", "add a slash command to pi", "register a pi tool", "hook a pi session event", "my pi extension broke", "pi won't start", "test a pi extension", "pi upgraded and my extension stopped working", or invokes /pi-extensions.
---

# pi extensions

Write a pi extension that cannot break pi, can be tested without spending a model call, and
fails visibly rather than silently when pi changes under it.

The worked example is `pi/extensions/helm-probe/` with its harness `pi/test.sh` — read those
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

## Layout and install

One directory per extension, entry point `index.ts`:

```
pi/extensions/<name>/index.ts     the extension
pi/extensions/<name>/README.md    what it is
pi/tests/<name>.mjs               its unit harness, found by name
```

The directory name is load-bearing — it is also the test filename, the command the extension
registers, and the first word it reports. Keep all four in step and the harness picks up a new
extension with no edit.

Install by symlink, so editing the repo is what ships:

```bash
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/<name>" ~/.pi/agent/extensions/<name>
```

Develop against an explicit path instead, which ignores whatever is installed:

```bash
pi --no-extensions -e "$PWD/pi/extensions/<name>/index.ts"
```

`--no-extensions` suppresses auto-discovery *and* `settings.json` entries, so with an explicit
`-e` exactly one extension loads regardless of what the machine has. Use it in every test.

`/reload` re-runs the factories on an edited file, so iterating does not need a session restart.
Do not hold a captured `ctx` across it.

## Test without a model

Four harnesses, none of which calls a model — `bash pi/test.sh [typecheck|unit|rpc|pty|all]`:

| Harness | Proves |
|---|---|
| `typecheck` | an API in use has changed. **The upgrade alarm.** |
| `unit` | the factory survives a deliberately mutilated pi. Milliseconds, no pi process. |
| `rpc` | it loads under the real loader, and its UI calls surface as frames |
| `pty` | a real interactive pi still reaches a prompt with it loaded |

Two facts make no-model testing possible: `session_start` fires at startup with no prompt, and
an extension command invoked over RPC as a `/`-prefixed prompt is handled locally. How each
harness works, and how to add one: `references/testing.md`.

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

- **`pi.getFlag()` in a factory returns the registered default, never the value on argv** — flags
  bind only after every extension has loaded. A flag-based kill switch reads correctly and does
  nothing. Use an environment variable for anything load-time.
- **Never vendor `typebox`** — pi aliases the specifier to its own bundled copy, so a local
  `node_modules/typebox` is ignored and a pinned version is a lie about what runs.
- **Never call an action method during load** (`sendMessage`, `exec`, `setModel`, …). They throw
  by design until the runtime binds. At factory time, only *register*.
- Old package names (`@sinclair/typebox`, `@mariozechner/pi-*`) still resolve through aliases but
  name packages that are not what runs. Import `typebox` and `@earendil-works/…`.

Each with the command that demonstrates it: `references/measured-traps.md`.

## Resources

- `references/reading-pi.md` — where each answer lives in the installed package, how to verify a claim, how to diff an upgrade
- `references/writing-a-total-factory.md` — the safety recipe, with the code
- `references/measured-traps.md` — surprising behaviour, each with the command that shows it
- `references/testing.md` — the four harnesses, why none needs a model, how to add one
