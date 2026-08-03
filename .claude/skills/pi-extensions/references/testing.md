# Testing an extension

Four harnesses, none of which calls a model. `pi/test.sh` is the working implementation; this is
what each one is for and why it exists.

```bash
bash pi/test.sh            # all four
bash pi/test.sh unit       # milliseconds, no pi process
```

Each harness **skips** rather than fails when its toolchain is absent, printing the skip. An
absent toolchain is a skip; a shipped extension with no unit harness is a **failure** — skipping
there leaves the one property that matters unverified while the suite reports green.

## Why none of them needs a model

- `session_start` fires at startup, with no prompt. An extension that reports there is observable
  the moment pi boots.
- An extension command invoked over RPC as a `/`-prefixed prompt is handled locally — no
  `agent_start`, nothing billed. This only holds for a *registered* command; an unrecognised
  `/name` is forwarded to the model as text. Prove registration first, and make that proof
  control flow.

## typecheck — the upgrade alarm

`tsc --noEmit` against the pi installed right now.

This is the load-bearing harness, because runtime is silent about a removed event: `pi.on()`
accepts any string. The types are the only place a deleted event or a changed signature is named.

Build a temp workspace, copy the extensions in, and symlink **pi's own** `typebox`, `pi-tui` and
`@types/node` beside them. Nothing vendored, no `node_modules` in the repo, and the types are
always whatever is actually installed:

```
$TMP/extensions/…                                       ← copied
$TMP/node_modules/@earendil-works/pi-coding-agent  →  $PI
$TMP/node_modules/@earendil-works/pi-tui           →  $PI/node_modules/@earendil-works/pi-tui
$TMP/node_modules/typebox                          →  $PI/node_modules/typebox
$TMP/node_modules/@types/node                      →  $PI/node_modules/@types/node
```

`tsconfig.json`: `strict`, `noEmit`, `module`/`moduleResolution` `NodeNext`, `types: ["node"]`,
`allowImportingTsExtensions`.

Point it at a candidate package to check an upgrade before installing it:
`PI_PACKAGE_DIR=/path/to/candidate bash pi/test.sh typecheck`.

Never pin an upper bound on the pi version — record what was verified, let newer through.

## unit — a fake pi, including a mutilated one

Import the module, call its default export with an object under test control. No pi process, no
model, milliseconds.

This is the only harness that can test the property that matters most: **the factory is total**.
It hands the factory pi objects that could not otherwise be produced —

```js
const extension = await import(extensionPath);

// registers what it claims
const record = { handlers: new Map(), commands: new Map(), tools: new Map() };
extension.default({
  on: (e, h) => record.handlers.set(e, h),
  registerCommand: (n, o) => record.commands.set(n, o),
  registerTool: (t) => record.tools.set(t.name, t),
});

// and survives every mutilation
extension.default({});                                    // no methods at all
extension.default(undefined);                             // not an object
extension.default({ on: () => { throw new Error("x") } }); // methods that throw
```

Cover at least: a missing method (feature detection), **one** throwing method among healthy ones
(per-capability isolation), all methods throwing, an empty object, and a non-object. The
single-throwing-sibling case is the one people omit, and without it collapsing the independent
guards into one shared `try` passes.

Assert on *behaviour*, not absence of a throw. "Does not throw" passed cleanly while a handler
dropped its entire report in silence — capture stderr and assert the output arrives.

Resolve `typebox` for the imported module by running it inside the same temp workspace the
typecheck builds. Node strips TypeScript types natively, so a `.ts` extension imports directly.

## rpc — the real loader

`pi --mode rpc` speaks one JSON frame per line on stdout and needs no TUI.

```bash
printf '%s\n' '{"id":"1","type":"get_commands"}' |
  pi --mode rpc --no-session --no-extensions -e "$EXT"
```

`--no-extensions` with an explicit `-e` means exactly one extension loads regardless of what the
machine has installed — without it the run inherits the developer's own extensions and stops
being reproducible.

Assert: pi exits 0; anything done through `ctx.ui` appears as an `extension_ui_request` frame;
the command appears in `get_commands`; **then** invoke it and assert no `agent_start` frame
appeared. Ordering is a safety property, not neatness — invoking an unregistered command reaches
the model.

## pty — a real interactive pi

The one thing RPC cannot show: that a real TUI still reaches a normal prompt.

`script` provides the pty. Feed `/dev/null` on stdin so pi renders and exits. BSD and util-linux
`script` take different argument shapes; detect with `script --version | grep -qi util-linux`.

Strip ANSI escapes from the capture, then assert both that pi rendered its banner (it reached a
prompt) and that the extension reported (it was actually loaded). Poll the capture for the
expected text with a bounded loop rather than sleeping a fixed time.

Cleaning up needs care: killing the backgrounded subshell does not reach `script`'s child. Plant a
token unique to the run in the child's argv via `env`, then `pkill -f "$token"` — a bare `pkill`
on the extension path also kills a concurrent run of the same suite.

Note `script` refuses a non-tty stdin on macOS, so this harness cannot type into pi. Anything
requiring interaction (`/reload`, for instance) has to be verified by a human, and should be
labelled as such wherever it is written down.

## Adding a harness for a new extension

If the extension directory name, its test filename, the command it registers and the first word
it reports all match, a name-driven harness picks it up with no edit. Keeping that convention is
cheaper than special-casing each extension.
