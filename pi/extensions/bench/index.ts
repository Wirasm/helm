/**
 * bench — pi's sensor for benchd (#358). The pi half of what `bench hook claude` is for Claude
 * Code: every event that says what the agent is doing goes to benchd, and benchd's reply
 * carries the agent's mail as pointer lines, which this puts in front of the model.
 *
 * It holds no mailroom. The mailbox, the address, the claim rule and the wake cap are benchd's,
 * spelled once in Rust; this file only reports and delivers. It reports by running
 * `bench hook pi` (the one command every harness uses) with the event on stdin, so the rules
 * that find benchd's socket (`BENCH_SUITE`, `BENCH_DIR`) are never restated here.
 *
 * Two ways mail reaches a pi agent, by its state:
 *
 * - **Busy.** `context` fires before every model request. It asks benchd for mail and appends
 *   the reply as a user message, so a notice lands at the next tool boundary. `context`
 *   changes the request, not the history, so what arrived in a run is re-sent on every request
 *   of that run and dropped when the next run starts (helm-mail measured both on 0.83.0).
 * - **Idle.** The session_start reply names the inbox. A watch on it asks benchd for the mail
 *   (`wake`) when something lands while pi is idle, and `sendUserMessage` starts a turn with
 *   it. benchd answers only when it also sees the agent idle and its wake cap allows a turn.
 *
 * The standing rule (what a notice is and what to do with one) goes into the system prompt of
 * every run, for the same reason: told once in `context`, it would be gone by the next run.
 *
 * Every failure is silence: no `bench`, no daemon, no mailbox. pi keeps working either way.
 *
 * Verified against pi 0.84.4.
 */

import { execFile } from "node:child_process";
import * as fs from "node:fs";
import type {
	ContextEvent,
	ExtensionAPI,
	ExtensionCommandContext,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const VERSION = "1";
const NAME = "bench";

/** How long one report may take before it counts as no answer. */
const HOOK_TIMEOUT_MS = 2000;

/** fs.watch is not guaranteed on every filesystem; a slow look behind it catches what it misses. */
const POLL_MS = 30_000;

const USES: readonly (keyof ExtensionAPI)[] = ["on", "registerCommand", "sendUserMessage"];

/** What benchd answers: `bench_wire::HookReply`. */
interface Reply {
	handle?: string;
	context?: string;
	inbox?: string;
	/** The standing rule, for the system prompt of every run. */
	rule?: string;
}

function warn(what: string, error: unknown): void {
	const reason =
		error instanceof Error ? error.message : typeof error === "string" ? error : JSON.stringify(error);
	console.error(`[${NAME}] ${what}: ${reason}`);
}

function step(what: string, run: () => void): boolean {
	try {
		run();
		return true;
	} catch (error) {
		warn(`${what} unavailable, skipping`, error);
		return false;
	}
}

function hasMethod(pi: ExtensionAPI, method: keyof ExtensionAPI): boolean {
	return typeof pi?.[method] === "function";
}

function notify(ctx: ExtensionContext | ExtensionCommandContext, message: string): boolean {
	if (typeof ctx?.ui?.notify !== "function") return false;
	ctx.ui.notify(message, "info");
	return true;
}

function announce(ctx: ExtensionContext | ExtensionCommandContext, message: string): void {
	if (!notify(ctx, message)) console.error(message);
}

/** The session's identity, as pi names it. */
function identity(ctx: ExtensionContext): { session: string; cwd: string } | undefined {
	try {
		const session = ctx?.sessionManager?.getSessionId?.();
		const cwd = ctx?.sessionManager?.getCwd?.() || ctx?.cwd || process.cwd();
		return session ? { session, cwd } : undefined;
	} catch {
		return undefined;
	}
}

/**
 * One report: `bench hook pi` with the event on stdin, the reply on stdout. `undefined` for
 * anything short of a reply: no `bench` on PATH (or `$BENCH`), no daemon, a timeout.
 */
function report(event: string, who: { session: string; cwd: string }): Promise<Reply | undefined> {
	return new Promise((resolve) => {
		try {
			const bench = process.env.BENCH || "bench";
			const child = execFile(
				bench,
				["hook", "pi"],
				{ timeout: HOOK_TIMEOUT_MS, encoding: "utf8" },
				(error, stdout) => {
					if (error) return resolve(undefined);
					try {
						resolve(JSON.parse(stdout.trim() || "{}") as Reply);
					} catch {
						resolve(undefined);
					}
				},
			);
			child.stdin?.on("error", () => {});
			child.stdin?.end(JSON.stringify({ hook_event_name: event, session_id: who.session, cwd: who.cwd }));
		} catch {
			resolve(undefined);
		}
	});
}

function install(pi: ExtensionAPI): void {
	const present = USES.filter((method) => hasMethod(pi, method));
	const missing = USES.filter((method) => !hasMethod(pi, method));
	if (missing.length > 0) {
		console.error(`[${NAME}] this pi is missing ${missing.join(", ")}; degrading to what is left`);
	}

	let who: { session: string; cwd: string } | undefined;
	let handle: string | undefined;
	let rule: string | undefined;
	/** Notices that arrived during this run: re-sent on every request of it. */
	let pending: string[] = [];
	let watcher: fs.FSWatcher | undefined;
	let poll: ReturnType<typeof setInterval> | undefined;
	let asking = false;

	function status(): string {
		return `${NAME} v${VERSION}: ${handle ? `you are ${handle} on the bench` : "no bench mailbox for this session"}`;
	}

	/** An event that only says what pi is doing. */
	function tell(event: string): void {
		if (who) void report(event, who);
	}

	/** Mail landed while idle: ask for it, and start a turn with whatever benchd hands over. */
	async function wake(ctx: ExtensionContext, inbox: string): Promise<void> {
		if (!who || asking || !hasMethod(pi, "sendUserMessage")) return;
		if (typeof ctx?.isIdle === "function" && !ctx.isIdle()) return;
		let waiting = false;
		try {
			waiting = fs.readdirSync(inbox).some((name) => name.endsWith(".md"));
		} catch {
			return;
		}
		if (!waiting) return;
		asking = true;
		try {
			const reply = await report("wake", who);
			if (reply?.context) pi.sendUserMessage(reply.context);
		} catch (error) {
			warn("could not start a turn with the mail", error);
		} finally {
			asking = false;
		}
	}

	function stopWatching(): void {
		watcher?.close();
		watcher = undefined;
		if (poll) clearInterval(poll);
		poll = undefined;
	}

	function watch(ctx: ExtensionContext, inbox: string): void {
		stopWatching();
		try {
			fs.mkdirSync(inbox, { recursive: true });
			watcher = fs.watch(inbox, () => void wake(ctx, inbox));
			watcher.on("error", () => stopWatching());
		} catch (error) {
			warn(`cannot watch ${inbox}; mail arrives with your next request`, error);
		}
		poll = setInterval(() => void wake(ctx, inbox), POLL_MS);
		poll.unref?.();
	}

	// `context` returns a new message list; its result type is inferred from pi's overload.
	async function inject(event: ContextEvent) {
		if (!who) return undefined;
		const reply = await report("context", who);
		if (reply?.context) pending.push(reply.context);
		if (pending.length === 0) return undefined;
		return {
			messages: [
				...event.messages,
				...pending.map((text) => ({
					role: "user" as const,
					content: [{ type: "text" as const, text }],
					timestamp: Date.now(),
				})),
			],
		};
	}

	if (present.includes("on")) {
		step("session_start handler", () =>
			pi.on("session_start", async (_event, ctx) => {
				who = identity(ctx);
				const reply = who ? await report("session_start", who) : undefined;
				handle = reply?.handle;
				rule = reply?.rule;
				if (reply?.inbox) watch(ctx, reply.inbox);
				announce(ctx, status());
			}),
		);
		step("session_shutdown handler", () =>
			pi.on("session_shutdown", () => {
				stopWatching();
				tell("session_shutdown");
			}),
		);
		step("agent_start handler", () =>
			pi.on("agent_start", () => {
				pending = [];
				tell("agent_start");
			}),
		);
		step("context handler", () => pi.on("context", (event) => inject(event)));
		// The rule has to be in every run: `context` changes one request, not the history.
		step("before_agent_start handler", () =>
			pi.on("before_agent_start", (event) =>
				rule ? { systemPrompt: `${event.systemPrompt}\n\n${rule}` } : undefined,
			),
		);
		step("tool_execution_end handler", () => pi.on("tool_execution_end", () => tell("tool_execution_end")));
		step("ui_prompt_start handler", () => pi.on("ui_prompt_start", () => tell("ui_prompt_start")));
		step("ui_prompt_end handler", () => pi.on("ui_prompt_end", () => tell("ui_prompt_end")));
		// Settled is idle: report it first, then look for mail that came in during the run.
		step("agent_settled handler", () =>
			pi.on("agent_settled", async (_event, ctx) => {
				if (!who) return;
				const reply = await report("agent_settled", who);
				if (reply?.inbox) await wake(ctx, reply.inbox);
			}),
		);
	}

	if (present.includes("registerCommand")) {
		step(`/${NAME} command`, () =>
			pi.registerCommand(NAME, {
				description: "Say whether this session has a bench mailbox, and its address",
				handler: async (_args, ctx) => {
					announce(ctx, status());
				},
			}),
		);
	}
}

export default function (pi: ExtensionAPI): void {
	try {
		install(pi);
	} catch (error) {
		warn("failed to install; the extension is inert for this session", error);
	}
}
