# Reading the installed pi

pi's extension API is pre-1.0. Treat the installed package as the only authority, and record
which version was read next to whatever is claimed.

```bash
PI=$(npm root -g)/@earendil-works/pi-coding-agent
node -p "require('$PI/package.json').version"
```

If `pi` is on `PATH` but that directory does not exist, the active node differs from the one that
installed pi (nvm, volta, a non-npm install). Resolve the real location before trusting anything;
a typecheck run against the wrong package proves nothing.

## Where each answer lives

| Question | Read |
|---|---|
| Which events exist? What is the exact handler signature? | `dist/core/extensions/types.d.ts` → `ExtensionAPI` |
| What can a handler return? What does a tool's `execute` resolve to? | same file → `ToolDefinition`, `RegisteredCommand`, `*EventResult` |
| What can `ctx` do inside a handler or command? | same file → `ExtensionContext`, `ExtensionCommandContext`, `ExtensionUIContext` |
| How are extensions discovered, in what order? | `dist/core/extensions/loader.js` → `discoverExtensionsInDir`, `discoverAndLoadExtensions` |
| Which module specifiers are rewritten, and to what? | same file → `VIRTUAL_MODULES`, `getAliases` |
| What happens when loading fails? | same file → `loadExtension`, then `dist/main.js` for the exit path |
| When do CLI flags reach `getFlag`? | `dist/core/agent-session-services.js` → `applyExtensionFlagValues` |
| What does `/reload` actually reload? | `dist/core/resource-loader.js` → `reload` |
| How do I drive pi headlessly, and what frames come back? | `docs/rpc.md` |
| Is there already an example of this? | `examples/extensions/` — ~70 files, one capability each |
| What broke in this release? | `CHANGELOG.md`, "Breaking Changes" |

`docs/extensions.md` is the readable overview and worth reading once end to end. It lags the
code. When prose and `dist/` disagree, `dist/` wins — and the disagreement is itself worth
writing down, because it usually marks a recent change.

## Verifying a claim

Reading source establishes what the code *says*. It does not establish behaviour — a control
flow can be subtler than it looks, and a claim that was true two releases ago can read as
still-true. Run it.

The cheapest sandbox uses a throwaway agent directory, so the real `~/.pi/agent/extensions` is
never touched. Symlink only the credential and model files in:

```bash
SB=$(mktemp -d)/agent; mkdir -p "$SB/extensions"
for f in auth.json models.json models-store.json; do ln -s "$HOME/.pi/agent/$f" "$SB/$f"; done

cat > "$SB/extensions/probe.ts" <<'TS'
export default function (pi) { console.error("PROBE " + typeof pi.on); }
TS

cd /tmp && printf '' | PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session
```

`PI_CODING_AGENT_DIR` relocates the whole agent directory, which is what makes the sandbox safe
and what lets a probe test auto-discovery rather than only an explicit `-e` path. Deliberately
not symlinked: `settings.json`, so the sandbox does not inherit configured extensions.

`--mode rpc` is the observation surface — one JSON frame per line on stdout, no TUI to scrape,
and an empty stdin makes pi start, emit, and exit. Anything an extension does through `ctx.ui`
surfaces as an `extension_ui_request` frame.

Never leave a deliberately broken extension in the real `~/.pi/agent/extensions`, even briefly.
A throwing factory there stops pi starting in every directory on the machine.

## After a pi upgrade

Order matters — cheapest signal first.

1. `CHANGELOG.md`, "Breaking Changes" for the new version. It names removed APIs explicitly.
2. Run the typecheck against the new package. It names anything removed from `ExtensionAPI`,
   which is the only place a deleted *event* becomes visible at all.
3. Run the rest of the suite. Behavioural assertions catch what the types cannot — an event that
   still exists but no longer fires, a frame that changed shape.
4. Only then read source, and only around what broke.

To check an upgrade *before* installing it, point the typecheck at a candidate package rather
than the active one:

```bash
PI_PACKAGE_DIR=/path/to/candidate bash pi/test.sh typecheck
```

Never pin an upper bound on the pi version. Record which version was verified and let a newer one
through — a version string is evidence for the reader, not a gate. Breaking loudly and fixing
forward beats a pin that quietly stops anyone upgrading.
