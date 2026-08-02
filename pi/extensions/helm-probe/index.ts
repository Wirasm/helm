/**
 * helm-probe — the reference shape for every pi extension helm owns.
 *
 * What it does is deliberately small: it reports which parts of pi's extension API this
 * pi actually gave it. That is trivial, but it is real — it is the answer to "is my
 * extension alive under this pi, and what does this pi still offer?", which is the first
 * question you ask after every pi upgrade.
 *
 * What it demonstrates is the point. Copy this directory to start the next extension and
 * delete the parts you do not need; the rules in ../../AGENTS.md come with it.
 *
 * THE ONE RULE THIS FILE EXISTS TO ENFORCE: the factory must be total.
 *
 * Measured on pi 0.83.0, 2026-08-02: a factory that throws takes the whole CLI down with
 * exit 1 — and because ~/.pi/agent/extensions is discovered in every directory, "our
 * extension is broken" and "pi does not start on this machine" are the same event. A
 * handler that throws is contained: pi emits extension_error and exits 0. So every line
 * below the try is allowed to fail, and no line above it is.
 *
 * Verified against pi 0.83.0, which exposes on/registerCommand/registerTool and
 * ctx.ui.notify. Every one of those is feature-detected anyway: this file is the thing
 * that has to keep working when a future pi removes one of them.
 */

import type {
	ExtensionAPI,
	ExtensionCommandContext,
	ExtensionContext,
	ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/** Bump when the report's shape changes; it is what a reader sees first. */
const VERSION = "1";
const NAME = "helm-probe";

/**
 * The kill switch: `HELM_PROBE_OFF=1 pi`. An environment variable and not a CLI flag,
 * because a registered flag cannot be read at load time — measured on 0.83.0,
 * `pi.getFlag()` inside a factory returns the registered *default*, never the value on
 * argv, since flags are bound from argv only after every extension has loaded
 * (`dist/core/agent-session-services.js:8`). A flag-based kill switch reads correctly
 * and does nothing, which is worse than not having one.
 */
const OFF_ENV = "HELM_PROBE_OFF";

/** The pi methods this extension uses. Each is probed before use, and named in the report. */
const USES = ["on", "registerCommand", "registerTool"] as const;

/** One line to stderr, prefixed so it is attributable in a busy terminal. */
function warn(what: string, error: unknown): void {
	const reason = error instanceof Error ? error.message : String(error);
	console.error(`[${NAME}] ${what}: ${reason}`);
}

/**
 * Run one registration. A failure disables that one capability and says so; it never
 * escapes into the factory, because an extension that can do nothing must still load.
 */
function step(what: string, run: () => void): boolean {
	try {
		run();
		return true;
	} catch (error) {
		warn(`${what} unavailable, skipping`, error);
		return false;
	}
}

/** Is this pi method actually present? Never assume — see the note about upgrades above. */
function hasMethod(pi: ExtensionAPI, method: keyof ExtensionAPI): boolean {
	return typeof (pi as unknown as Record<string, unknown>)[method] === "function";
}

/**
 * Notify through the UI if there is one. In a TUI this is a notification; under
 * `pi --mode rpc` it surfaces as an extension_ui_request frame, which is how the test
 * harness observes this extension without spending a model call.
 */
function notify(ctx: ExtensionContext | ExtensionCommandContext, message: string): boolean {
	const ui = (ctx as Partial<ExtensionContext>).ui as Partial<ExtensionUIContext> | undefined;
	if (typeof ui?.notify !== "function") return false;
	ui.notify(message, "info");
	return true;
}

/** What this pi gave us, split into what we can use and what has gone missing. */
function report(present: readonly string[], missing: readonly string[]): string {
	const lines = [`${NAME} v${VERSION}`, `present: ${present.join(", ") || "(none)"}`];
	if (missing.length > 0) lines.push(`MISSING: ${missing.join(", ")}`);
	return lines.join("\n");
}

function install(pi: ExtensionAPI): void {
	const present = USES.filter((method) => hasMethod(pi, method));
	const missing = USES.filter((method) => !hasMethod(pi, method));
	const text = report(present, missing);

	// A pi that lost a method we use is not an error — it is the upgrade we were told to
	// survive. Say it once, plainly, and carry on with whatever is left.
	if (missing.length > 0) {
		console.error(`[${NAME}] this pi is missing ${missing.join(", ")}; degrading to what is left`);
	}

	if (hasMethod(pi, "on")) {
		step("session_start handler", () =>
			pi.on("session_start", (_event, ctx) => {
				notify(ctx, text);
			}),
		);
	}

	if (hasMethod(pi, "registerCommand")) {
		step("/helm-probe command", () =>
			pi.registerCommand(NAME, {
				description: "Report which pi extension APIs this session offers",
				handler: async (_args, ctx) => {
					if (!notify(ctx, text)) console.error(text);
				},
			}),
		);
	}

	if (hasMethod(pi, "registerTool")) {
		step("helm_probe tool", () =>
			pi.registerTool({
				name: "helm_probe",
				label: "Helm probe",
				description: "Report which pi extension APIs the current session offers.",
				// TypeBox 1.3.7 — pi supplies it; never vendor it, a local copy is ignored.
				parameters: Type.Object({}),
				async execute() {
					return { content: [{ type: "text", text }], details: { present, missing } };
				},
			}),
		);
	}
}

export default function (pi: ExtensionAPI): void {
	// The one total try in the file. Swallowing here is the whole point: without it, one
	// throw below takes pi down in every directory on the machine. It is never silent —
	// warn() puts the reason on stderr, and pi reaches its prompt with us simply absent.
	try {
		if (process.env[OFF_ENV]) return;
		install(pi);
	} catch (error) {
		warn("failed to install; the extension is inert for this session", error);
	}
}
