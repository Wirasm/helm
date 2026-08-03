# Writing a total factory

An extension is a module whose default export is a factory that pi calls with an `ExtensionAPI`.
Everything below is about that function, because it is the only part that can break pi itself.

## Why it has to be total

pi loads every extension it discovers before it starts. A factory that throws becomes a load
error, and any load error is fatal: pi prints `Failed to load extension …`, suggests `pi -ne`,
and exits 1.

The blast radius is what makes this a safety rule rather than a style one. `~/.pi/agent/extensions`
is discovered in **every** directory, so a broken extension does not break one project — it stops
pi starting anywhere on the machine, in work that has nothing to do with the extension.

A throwing *handler* is contained by comparison: pi emits an `extension_error` frame and exits 0.
The session survives, and the failure is attributable.

So: below the factory, throw freely — it costs one frame. Inside it, never.

## The shape

```ts
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const NAME = "example";
const USES: readonly (keyof ExtensionAPI)[] = ["on", "registerCommand"];

/** One attributable line to stderr. Degrading is fine; degrading in silence is the defect. */
function warn(what: string, error: unknown): void {
  const reason =
    error instanceof Error ? error.message : typeof error === "string" ? error : JSON.stringify(error);
  console.error(`[${NAME}] ${what}: ${reason}`);
}

/** One registration. A failure disables that capability and says so — never its siblings. */
function step(what: string, run: () => void): void {
  try {
    run();
  } catch (error) {
    warn(`${what} unavailable, skipping`, error);
  }
}

/** Probe before calling. A pi that dropped a method must leave the extension inert, not fatal. */
function hasMethod(pi: ExtensionAPI, method: keyof ExtensionAPI): boolean {
  return typeof pi[method] === "function";
}

function install(pi: ExtensionAPI): void {
  const present = USES.filter((m) => hasMethod(pi, m));
  const missing = USES.filter((m) => !hasMethod(pi, m));
  if (missing.length > 0) {
    console.error(`[${NAME}] this pi is missing ${missing.join(", ")}; degrading to what is left`);
  }

  if (present.includes("on")) {
    step("session_start handler", () => pi.on("session_start", (_event, ctx) => announce(ctx, "…")));
  }
  // …one independent block per capability
}

export default function (pi: ExtensionAPI): void {
  // The one total try. Swallowing here is the entire point: without it, one throw below stops
  // pi starting in every directory. It is never silent — warn() puts the reason on stderr.
  try {
    if (process.env[`${NAME.toUpperCase()}_OFF`]) return;
    install(pi);
  } catch (error) {
    warn("failed to install; the extension is inert for this session", error);
  }
}
```

## The rules this encodes

1. **One `try` around the whole factory body.** The catch prints and returns. That is not
   swallowing an error — it is the difference between "this extension is broken" and "pi is
   broken on this machine".
2. **Feature-detect every pi method before calling it.** A future pi that drops a method must
   leave the extension inert, not fatal.
3. **Guard each registration separately.** `hasMethod` and `step` catch different things —
   *absent* versus *present but throwing* — and both are needed. One failure must not take its
   siblings with it.
4. **Only register at factory time.** Action methods (`sendMessage`, `sendUserMessage`, `exec`,
   `setModel`, …) throw by design until the runtime binds, with "Extension runtime not
   initialized". Calling one during load is a self-inflicted fatal.
5. **Never degrade in silence.** A UI call that reports "no UI here" must fall back to stderr,
   not just return. Prefer one `announce()`-style helper that every caller uses, so a caller
   cannot forget:

   ```ts
   function announce(ctx: ExtensionContext, message: string): void {
     if (typeof ctx.ui?.notify !== "function") console.error(message);
     else ctx.ui.notify(message, "info");
   }
   ```

   This is the failure mode most easily shipped: the extension degrades perfectly and says
   nothing, so nobody learns it stopped working. A test asserting only "does not throw" passes
   straight through it — assert that the output *arrives*.

6. **Give it an off switch that works.** An environment variable checked at the top of the
   factory, not a registered CLI flag — flags do not hold their argv value at load time
   (see `measured-traps.md`).

## Type strictly, defend at runtime

These two pull in opposite directions and both matter:

- The parameter is typed `ExtensionAPI` — strictly — because that is what makes a removed API a
  compile error. It is the only upgrade alarm available.
- The body defends against a shape the type says is impossible, because pi's loader is untyped
  JavaScript and a type annotation enforces nothing at runtime.

Do not resolve the tension by loosening the type. Widening to `ExtensionAPI | undefined` buys no
runtime safety — the outer `try` already covers it — and costs the compile-time signal that is
the whole point. Keep the strict signature and let the runtime checks be the belt.
