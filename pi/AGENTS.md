# AGENTS.md — pi extensions

helm's repo owns helm's pi work. These are extensions for the **pi sessions helm hosts**,
in whatever repo the user is in — not for agents working on helm. That is why they live
here and are symlinked into `~/.pi/agent/extensions/`, and not in helm's own
`.pi/extensions/`, which would load them only inside this checkout.

Everything below was measured against **pi 0.83.0 on 2026-08-02**, not read off a doc. Where it
says "measured", there is a command in `test.sh` that shows it. Exactly one claim here rests on
a human watching instead — `/reload` — and it says so where it appears. Keep that distinction
when you add to this file: what a command proved and what someone reported are not the same
kind of fact, and a reader deserves to know which one they are getting.

## The rule that matters

**A factory that throws takes the entire pi CLI down.** `exit 1`, plus
`Hint: Start without extensions using "pi -ne".` And because `~/.pi/agent/extensions` is
discovered in *every* directory, one bad extension of ours means pi does not start anywhere on
the machine — nothing to do with helm. A handler that throws is contained: pi emits
`extension_error` and exits 0.

So the split is absolute:

- **Below the factory's `try`** — handlers, commands, tools — anything may throw. It costs one
  `extension_error`.
- **Inside the factory** — nothing may throw. Ever.

Which gives four rules, all of them visible in `extensions/helm-probe/index.ts`:

1. **The whole factory body is inside one `try`.** The catch prints one attributable line to
   stderr and returns. That is not swallowing an error — it is the difference between "our
   extension is broken" and "pi is broken on this machine".
2. **Feature-detect every pi method before calling it** (`hasMethod`). A future pi that drops a
   method must leave us inert, not fatal.
3. **Each registration is its own guarded step** (`step()`). One failure disables one
   capability and says so; the others stay installed.
4. **Never call an action method during load.** `pi.sendMessage`, `pi.exec`, `pi.setModel` and
   friends throw *by design* until the runtime is bound — "Extension runtime not initialized"
   (`createExtensionRuntime` in `dist/core/extensions/loader.js`). At factory time you may only
   *register*.
5. **Inert is not the same as silent, and only one of them is acceptable.** Degrading must
   always leave a trace. The reference for this is `announce()`: a UI call that returns "no UI
   here" must fall back to stderr, never just return. A review of this very file caught
   `session_start` discarding that return value — it degraded perfectly and said nothing at
   all, which is the one outcome this whole directory exists to prevent.

## Traps measured on 0.83.0

- **`pi.getFlag()` in a factory returns the registered default, never the value on argv.**
  Flags are bound from argv only after every extension has loaded
  (`applyExtensionFlagValues` in
  `dist/core/agent-session-services.js`). A flag-based kill switch therefore reads correctly
  and does nothing. Use an environment variable for anything load-time; a flag is
  fine inside a handler, where it holds the real value. Measured: factory `false`, handler
  `true`, for the same `--trap-me` on the same run.
- **Subscribing to an event pi no longer has succeeds silently.** `pi.on()` only pushes into a
  Map — no validation, no warning, and the handler simply never fires
  (the `on()` in `createExtensionAPI`, `dist/core/extensions/loader.js`). Nothing at runtime
  will tell you. Two things catch it, and you need both: the **typecheck**, which names the
  event, and a **behavioural assertion** in the suite, which notices the effect went
  missing. This is why extensions
  here import the real `ExtensionAPI` type instead of duck-typing the API surface — duck-typing
  keeps the build green through exactly the upgrade you needed to hear about.
- **TypeBox is 1.3.7 and pi supplies it.** `Type.Base`, `Type.Awaited`, `Type.Promise`,
  `Type.AsyncIterator`, `Type.Iterator`, `Type.Options` and `Value.Mutate` are gone as of
  0.83.0. **Never vendor typebox**: a `node_modules/typebox` beside the extension is ignored,
  because pi's loader aliases the specifier to its own copy (`getAliases` in
  `dist/core/extensions/loader.js`). Measured — an extension in a directory with typebox
  1.1.38 installed still ran against 1.3.7.
- **Import `typebox` and `@earendil-works/…`, not the old names.** `@sinclair/typebox` and
  `@mariozechner/pi-*` still resolve — the loader aliases them — but they name a package that
  is not what runs.

## Layout

```
pi/
  extensions/<name>/index.ts    the extension — one directory each, entry point index.ts
  extensions/<name>/README.md   what it is, and how to install it
  tests/<name>.mjs              its unit harness, found by name
  test.sh                       the test command
```

pi discovers three forms: `<dir>/*.ts`, `<dir>/*/index.ts`, and `<dir>/*/package.json` with a
`pi.extensions` array. We use **`<dir>/index.ts`**. The directory gives an extension a home for
its README; the `package.json` form buys nothing until we publish to a registry and its
`dependencies` field is actively misleading for the one dependency an extension has (see the
typebox trap above). When publishing lands, adding the manifest is a one-file change.

Only directories go under `extensions/`. A stray `.ts` at that level would be discovered as its
own extension. Files *beside* an `index.ts` inside an extension directory are never
auto-discovered, so helpers are safe there.

## Install

```bash
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/helm-probe" ~/.pi/agent/extensions/helm-probe
```

A symlink, so editing in the repo is what ships — pi honours symlinks at both discovery levels.
Remove it to uninstall. Nothing is copied, nothing is built.

## The dev loop

```bash
pi --no-extensions -e "$PWD/pi/extensions/helm-probe/index.ts"   # isolated, ignores what is installed
```

`--no-extensions` suppresses auto-discovery **and** `settings.json` entries (measured), so with
an explicit `-e` you see exactly one extension no matter what the machine has. Use it in every
test; without it a run picks up whatever else is installed and stops being reproducible.

**`/reload` works — so iterating on an extension does not need a session restart.** Edit the
file, `/reload` in the running session, and the new factory is what answers next. That is the
iteration loop: no restart, no lost context, no relaunching whatever the session was in the
middle of.

Provenance matters here, because the rest of this file is careful about it: this one is
**verified by the operator, by hand, not by a command**. The automation could not watch it —
`script` refuses a non-tty stdin on macOS and an `expect`-driven TUI produced no observable
result either way — so there is no harness assertion behind this line, and `bash pi/test.sh`
deliberately does not depend on reload. The source agrees (`reload` in
`dist/core/resource-loader.js` clears the extension cache and re-resolves both discovered and
`-e` paths), but source reading is not evidence of behaviour. A human watched it.

Do not hold a captured `ctx` across a reload — pi invalidates it, and the stale ctx throws with
an explanatory message (`assertActive` in `dist/core/extensions/loader.js`).

## Testing

```bash
bash pi/test.sh            # all four — this directory's gate
bash pi/test.sh unit       # milliseconds, no pi process
```

**This is its own gate, and it runs when you touch `pi/` — not as part of the Swift one.**
helm's gate needs only the Swift toolchain and xcodegen; this needs node and a `tsc`. Bolting
them together would mean every Swift contributor and every fresh worktree had to install a JS
toolchain before the repo could go green, which is too high a price for one command.

| Harness | What only it can prove | Cost |
|---|---|---|
| `typecheck` | An API we use has changed. **The upgrade alarm.** | `tsc --noEmit` |
| `unit` | The factory is total, against a deliberately mutilated pi. | milliseconds |
| `rpc` | It loads under the real loader and its UI call surfaces. | one pi process |
| `pty` | A real interactive pi reaches a normal prompt with it loaded. | one pi process |

**No harness calls a model.** `session_start` fires at startup, and an extension command
invoked as a `/`-prefixed prompt over RPC is handled locally — measured, no `agent_start`
frame. The rpc harness proves the command is registered *before* it invokes it, because a
`/name` that is not a registered command would be sent to the model.

The typecheck runs against whatever pi is **installed right now** — `test.sh` symlinks pi's own
`typebox`, `pi-tui` and `@types/node` into a temp workspace. Nothing is vendored and there is no
pinned upper bound: a newer pi is evidence, never a gate. `PI_PACKAGE_DIR=… bash pi/test.sh
typecheck` points it at a candidate upgrade before you install one.

Each harness **skips** rather than fails when its *toolchain* is missing, so this still runs
usefully on a machine with only some of it. Skips are printed, never silent. `tsc` comes from
`npm install` in this directory.

An absent toolchain is a skip. **A shipped extension with no `tests/<name>.mjs` is a failure**,
not a skip — skipping there would leave "the factory is total" unverified while the gate stayed
green, which is the exact false-green this suite exists to prevent.

## The name is load-bearing

An extension's directory name is used three times, and `test.sh` relies on all three:

| Where | Must be |
|---|---|
| `extensions/<name>/index.ts` | the extension |
| `tests/<name>.mjs` | its unit harness — found by name |
| the command it registers, and the first word of what it reports | `<name>` |

That is what lets `rpc` and `pty` cover every extension rather than a hard-coded one. An
extension that deliberately breaks the convention must extend those two harnesses itself —
otherwise it will fail them, loudly, which is the right default.

## Starting the next extension

Copy `extensions/helm-probe/` to `extensions/<name>/`, copy `tests/helm-probe.mjs` to
`tests/<name>.mjs`, rename `helm-probe`/`helm_probe`/`HELM_PROBE_OFF` throughout, and delete
what you do not need. The rules above come with the file, and all four harnesses pick the new
extension up by name with no edit to `test.sh` — verified by doing exactly this and running
two extensions side by side.
