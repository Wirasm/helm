# Measured traps

Behaviour that surprises, each with the command that shows it. Measured on **pi 0.83.0**. Re-run
any of these against a newer pi rather than assuming they still hold — that is what they are for.

Every command below uses a sandboxed agent directory (`references/reading-pi.md` → Verifying a
claim) so the real `~/.pi/agent/extensions` is never touched.

## A throwing factory is fatal; a throwing handler is not

```bash
echo 'export default function(){ throw new Error("BOOM") }' > "$SB/extensions/boom.ts"
cd /tmp && printf '' | PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session
# exit 1 — Error: Failed to load extension … BOOM
#          Hint: Start without extensions using "pi -ne".
```

Same from any directory: auto-discovery is global. Now the contained case:

```bash
cat > "$SB/extensions/boom.ts" <<'TS'
export default function (pi) { pi.on("session_start", () => { throw new Error("BOOM") }); }
TS
cd /tmp && printf '' | PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session
# exit 0 — {"type":"extension_error","event":"session_start","error":"BOOM"}
```

## Subscribing to an event that does not exist succeeds silently

```bash
cat > "$SB/extensions/probe.ts" <<'TS'
export default function (pi) {
  pi.on("event_that_does_not_exist", () => { throw new Error("never") });
  console.error("PROBE subscription returned normally");
}
TS
# prints the line, pi exits 0, nothing warns, the handler never fires
```

`pi.on()` only pushes into a map — no validation. This is *the* argument for importing the real
`ExtensionAPI` type: the typecheck is the only thing that names a removed event, and a
behavioural assertion is the only thing that notices the effect went missing. Runtime says
nothing, forever.

## `pi.getFlag()` in a factory returns the default, never argv

```bash
cat > "$SB/extensions/flag.ts" <<'TS'
export default function (pi) {
  pi.registerFlag("trap-me", { type: "boolean", default: false, description: "x" });
  console.error("FACTORY " + String(pi.getFlag("trap-me")));
  pi.registerCommand("trap", { description: "x", handler: async () => {
    console.error("HANDLER " + String(pi.getFlag("trap-me")));
  }});
}
TS
printf '{"type":"prompt","message":"/trap"}\n' |
  PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session --trap-me
# FACTORY false
# HANDLER true
```

`applyExtensionFlagValues` runs *after* every factory, so a factory can only ever see the value
it just registered as the default. A flag-based kill switch therefore reads correctly and does
nothing — use an environment variable for anything that must take effect at load time. Flags are
fine inside a handler, where they hold the real value.

## A vendored `typebox` is ignored

```bash
mkdir /tmp/tb && cd /tmp/tb
printf '{"name":"t","type":"module","dependencies":{"typebox":"1.1.38"}}' > package.json
npm install --silent
cat > ext.ts <<'TS'
import * as TB from "typebox";
export default function () { console.error("hasOptions=" + ("Options" in TB.Type)); }
TS
node -e "console.log('local copy hasOptions=' + ('Options' in require('typebox').Type))"
pi --mode rpc --no-session --no-extensions -e ./ext.ts < /dev/null
# local copy hasOptions=true      ← what is installed beside the extension
# hasOptions=false                ← what actually runs
```

pi's loader rewrites the specifier to its own bundled copy (`getAliases`), so a pinned version in
`package.json` is a statement about nothing. Never vendor it; typecheck against pi's copy instead.

The same alias map keeps `@sinclair/typebox` and `@mariozechner/pi-*` resolving. They work, but
they name packages that are not what runs — import `typebox` and `@earendil-works/…`.

## Action methods throw during load

`sendMessage`, `sendUserMessage`, `appendEntry`, `exec`, `setModel` and friends are stubs until
the runtime binds, and throw "Extension runtime not initialized. Action methods cannot be called
during extension loading." At factory time only *register*; do the acting from a handler.

## `--no-extensions` also suppresses `settings.json` extensions

The CLI help says "Disable extension discovery (explicit -e paths still work)", which undersells
it — configured `extensions` entries in `settings.json` are dropped too.

```bash
printf '{"extensions":["/tmp/settings-ext.ts"]}' > "$SB/settings.json"
PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session               # both load
PI_CODING_AGENT_DIR="$SB" pi --mode rpc --no-session --no-extensions  # neither loads
```

That is what makes `--no-extensions -e <path>` a reproducible test environment: exactly one
extension, regardless of what the machine has installed. Use it in every harness.

## An extension command over RPC does not reach the model

```bash
printf '{"type":"prompt","message":"/my-command"}\n' |
  pi --mode rpc --no-session --no-extensions -e ./ext.ts |
  grep -o '"type":"[a-z_]*"' | sort | uniq -c
#   2 "type":"extension_ui_request"
#   1 "type":"response"          ← no agent_start: nothing was billed
```

A `/`-prefixed prompt naming a registered command is handled locally. **But only if it is
registered** — an unrecognised `/name` is forwarded to the model as ordinary text and costs a
real call. Prove registration with `get_commands` *before* invoking, and make that check control
flow rather than a bare assertion.

## Discovery forms and order

Three forms, one level deep, symlinks honoured at both levels:

- `<dir>/*.ts` and `<dir>/*.js`
- `<dir>/*/index.ts` or `index.js`
- `<dir>/*/package.json` carrying a `pi.extensions` array

Roots load in order: project `.pi/extensions/` (after trust) → `~/.pi/agent/extensions/` →
`settings.json` → `-e`. Files *beside* an `index.ts` inside an extension directory are never
auto-discovered, so helpers are safe there — but a stray `.ts` at the root of an extensions
directory becomes its own extension.
