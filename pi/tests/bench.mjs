/**
 * bench unit harness — a fake pi and a fake `bench`, no pi process, no daemon, no model.
 *
 * The fake `bench` is a shell script named by `$BENCH`: it appends each request it gets on
 * stdin to a log and answers with whatever `reply.json` holds at that moment, so a test can
 * say what benchd would answer and read back what the extension reported.
 *
 * Usage: node pi/tests/bench.mjs <path-to-extension-index.ts>
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const extensionPath = process.argv[2];
if (!extensionPath) {
	console.error("usage: node bench.mjs <path-to-extension-index.ts>");
	process.exit(2);
}

let failures = 0;
let current = "";

function ok(message) {
	console.log(`ok - ${message}`);
}

function fail(message) {
	failures += 1;
	console.log(`not ok - ${current}: ${message}`);
}

function check(condition, message) {
	if (condition) return true;
	fail(message);
	return false;
}

async function test(name, run) {
	current = name;
	const before = failures;
	try {
		await run();
	} catch (error) {
		fail(`threw ${error instanceof Error ? error.stack : String(error)}`);
		return;
	}
	if (failures === before) ok(name);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait up to a second for `done()`: the inbox watch can run a wake of its own meanwhile. */
async function eventually(done) {
	for (let i = 0; i < 50 && !done(); i++) await sleep(20);
	return done();
}

/** A fake `bench` in its own directory; `answer(json)` sets its next replies. */
function fakeBench() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-ext-bench-"));
	const log = path.join(dir, "requests.log");
	const reply = path.join(dir, "reply.json");
	const script = path.join(dir, "bench");
	fs.writeFileSync(reply, "{}");
	fs.writeFileSync(
		script,
		`#!/bin/sh\n[ "$1 $2" = "hook pi" ] || exit 9\ncat >> '${log}'\necho >> '${log}'\ncat '${reply}'\n`,
		{ mode: 0o755 },
	);
	process.env.BENCH = script;
	return {
		dir,
		answer: (value) => fs.writeFileSync(reply, JSON.stringify(value)),
		requests: () =>
			fs.existsSync(log)
				? fs
						.readFileSync(log, "utf8")
						.split("\n")
						.filter(Boolean)
						.map((line) => JSON.parse(line))
				: [],
		done: () => fs.rmSync(dir, { recursive: true, force: true }),
	};
}

function recordingPi(overrides = {}) {
	const record = { handlers: new Map(), commands: new Map(), sent: [] };
	const base = {
		on(event, handler) {
			record.handlers.set(event, handler);
		},
		registerCommand(name, options) {
			record.commands.set(name, options);
		},
		sendUserMessage(content, options) {
			record.sent.push({ content, options });
		},
	};
	return { pi: { ...base, ...overrides }, record };
}

function recordingCtx(sessionId = "019f-aaaa-bbbb", cwd = "/tmp/pi-bench-cwd") {
	const messages = [];
	const idle = { value: true };
	return {
		ctx: {
			ui: { notify: (message) => messages.push(message) },
			mode: "tui",
			cwd,
			sessionManager: { getSessionId: () => sessionId, getCwd: () => cwd },
			isIdle: () => idle.value,
		},
		messages,
		idle,
	};
}

function capturingStderr(body) {
	const lines = [];
	const original = console.error;
	console.error = (...args) => lines.push(args.join(" "));
	try {
		body();
	} finally {
		console.error = original;
	}
	return lines;
}

async function capturingStderrAsync(body) {
	const lines = [];
	const original = console.error;
	console.error = (...args) => lines.push(args.join(" "));
	try {
		await body();
	} finally {
		console.error = original;
	}
	return lines;
}

const factory = (await import(extensionPath)).default;
if (typeof factory !== "function") {
	console.log("not ok - extension does not default-export a factory function");
	process.exit(1);
}

function started() {
	const { pi, record } = recordingPi();
	factory(pi);
	return { pi, record, ...recordingCtx() };
}

const user = (text) => ({ role: "user", content: [{ type: "text", text }] });

await test("registers the events it reports, the context handler and the /bench command", () => {
	const { record } = started();
	for (const event of [
		"session_start",
		"session_shutdown",
		"agent_start",
		"context",
		"tool_execution_end",
		"ui_prompt_start",
		"ui_prompt_end",
		"agent_settled",
		"before_agent_start",
	]) {
		check(record.handlers.has(event), `no ${event} handler`);
	}
	check(record.commands.has("bench"), "no /bench command");
});

await test("session_start reports the session and says the address benchd gave it", async () => {
	const bench = fakeBench();
	try {
		bench.answer({ handle: "helm-a1b2" });
		const { record, ctx, messages } = started();
		await record.handlers.get("session_start")({ reason: "startup" }, ctx);
		const [first] = bench.requests();
		check(first?.hook_event_name === "session_start", `reported ${JSON.stringify(first)}`);
		check(first?.session_id === "019f-aaaa-bbbb" && first?.cwd === "/tmp/pi-bench-cwd", JSON.stringify(first));
		check(messages[0] === "bench v1: you are helm-a1b2 on the bench", `said ${messages[0]}`);
	} finally {
		bench.done();
	}
});

await test("mail benchd hands over at a model request is new once, then stays where it arrived", async () => {
	const bench = fakeBench();
	try {
		const { record, ctx } = started();
		await record.handlers.get("session_start")({}, ctx);
		const inject = record.handlers.get("context");
		const texts = (result) => result?.messages?.map((m) => m.content[0].text).join(" | ");
		bench.answer({ handle: "h", context: "mail m1" });
		const first = await inject({ messages: [user("go")] }, ctx);
		check(texts(first) === "go | mail m1", `first request: ${texts(first)}`);

		// The agent read m1 and replied; benchd hands over nothing new. m1 stays before that.
		bench.answer({ handle: "h" });
		const second = await inject({ messages: [user("go"), user("read m1"), user("replied")] }, ctx);
		check(texts(second) === "go | mail m1 | read m1 | replied", `second request: ${texts(second)}`);
		check(
			second?.messages?.[1]?.timestamp === first?.messages?.[1]?.timestamp,
			"the notice keeps the moment it arrived",
		);

		// A second notice arrives later in the run: it is new now, and m1 stays where it was.
		bench.answer({ handle: "h", context: "mail m2" });
		const third = await inject({ messages: [user("go"), user("read m1"), user("replied"), user("more")] }, ctx);
		check(texts(third) === "go | mail m1 | read m1 | replied | more | mail m2", `third request: ${texts(third)}`);

		// pi compacts mid-run: the list shrinks and every index moves. Notices already sent go;
		// one arriving now is placed at the end of the compacted list.
		bench.answer({ handle: "h", context: "mail m4" });
		const compacted = await inject({ messages: [user("summary"), user("x")] }, ctx);
		check(texts(compacted) === "summary | x | mail m4", `after compaction: ${texts(compacted)}`);

		record.handlers.get("agent_start")({}, ctx);
		bench.answer({ handle: "h" });
		const next = await inject({ messages: [user("next run")] }, ctx);
		check(next === undefined, "a new run starts without them");
	} finally {
		bench.done();
	}
});

await test("mail that lands while idle starts a turn with what benchd hands over; busy, it waits", async () => {
	const bench = fakeBench();
	try {
		const inbox = path.join(bench.dir, "inbox");
		bench.answer({ handle: "h", inbox });
		const { record, ctx, idle } = started();
		await record.handlers.get("session_start")({}, ctx);
		bench.answer({ handle: "h", inbox, context: "You have mail from a: /x/m1.md" });

		idle.value = false;
		fs.writeFileSync(path.join(inbox, "m1.md"), "x");
		await sleep(300);
		check(record.sent.length === 0, "a busy pi was sent a turn");
		check(!bench.requests().some((r) => r.hook_event_name === "wake"), "a busy pi asked for its mail");

		idle.value = true;
		await record.handlers.get("agent_settled")({}, ctx);
		check(record.sent.length === 1, `sent ${JSON.stringify(record.sent)}`);
		check(record.sent[0]?.content === "You have mail from a: /x/m1.md", "the turn carries the notice");
		const events = bench.requests().map((r) => r.hook_event_name);
		check(
			events.join(",").endsWith("agent_settled,wake"),
			`settled is reported before the wake: ${events.join(",")}`,
		);
		record.handlers.get("session_shutdown")({}, ctx);
	} finally {
		bench.done();
	}
});

await test("a turn that cannot start sends the notice with the next request instead", async () => {
	const bench = fakeBench();
	try {
		const inbox = path.join(bench.dir, "inbox");
		bench.answer({ handle: "h", inbox });
		const { pi, record } = recordingPi({
			sendUserMessage() {
				throw new Error("compaction in progress");
			},
		});
		factory(pi);
		const { ctx } = recordingCtx();
		await record.handlers.get("session_start")({}, ctx);
		bench.answer({ handle: "h", context: "You have mail from a: /x/m1.md" });
		await record.handlers.get("agent_settled")({}, ctx);
		await eventually(() => bench.requests().some((r) => r.hook_event_name === "wake"));
		await sleep(100);
		// More mail arrives with that request: both land at the same place, in arrival order.
		bench.answer({ handle: "h", context: "You have mail from b: /x/m2.md" });
		const next = await record.handlers.get("context")({ messages: [user("go")] }, ctx);
		const texts = next?.messages?.map((m) => m.content[0].text);
		check(
			texts?.join(" | ") === "go | You have mail from a: /x/m1.md | You have mail from b: /x/m2.md",
			JSON.stringify(texts),
		);
		record.handlers.get("session_shutdown")({}, ctx);
	} finally {
		bench.done();
	}
});

await test("the wake asks to steer, so a turn that started meanwhile takes it instead", async () => {
	const bench = fakeBench();
	try {
		bench.answer({ handle: "h", inbox: path.join(bench.dir, "inbox") });
		const { record, ctx } = started();
		await record.handlers.get("session_start")({}, ctx);
		bench.answer({ handle: "h", context: "You have mail from a: /x/m1.md" });
		await record.handlers.get("agent_settled")({}, ctx);
		await eventually(() => record.sent.length > 0);
		check(record.sent[0]?.options?.deliverAs === "steer", JSON.stringify(record.sent));
		record.handlers.get("session_shutdown")({}, ctx);
	} finally {
		bench.done();
	}
});

await test("benchd saying no (no context) starts no turn", async () => {
	const bench = fakeBench();
	try {
		const inbox = path.join(bench.dir, "inbox");
		bench.answer({ handle: "h", inbox });
		const { record, ctx } = started();
		await record.handlers.get("session_start")({}, ctx);
		fs.writeFileSync(path.join(inbox, "m1.md"), "x");
		await record.handlers.get("agent_settled")({}, ctx);
		check(record.sent.length === 0, "a turn started without mail handed over");
		record.handlers.get("session_shutdown")({}, ctx);
	} finally {
		bench.done();
	}
});

await test("a ctx gone stale under the inbox watch neither throws nor keeps watching", async () => {
	// Archon runs one pi session per workflow node in one process. A replaced session's ctx
	// throws on every use (pi 1.0's assertActive), and a rejection that escaped the watch's
	// `void wake(ctx)` killed the whole host.
	const bench = fakeBench();
	const rejections = [];
	const onRejection = (error) => rejections.push(error);
	process.on("unhandledRejection", onRejection);
	try {
		const inbox = path.join(bench.dir, "inbox");
		bench.answer({ handle: "h", inbox });
		const { record, ctx } = started();
		await record.handlers.get("session_start")({}, ctx);
		bench.answer({ handle: "h", inbox, context: "You have mail from a: /x/m1.md" });
		ctx.isIdle = () => {
			throw new Error("This extension ctx is stale after session replacement or reload.");
		};
		const warnings = await capturingStderrAsync(async () => {
			fs.writeFileSync(path.join(inbox, "m1.md"), "x");
			await sleep(300);
		});
		check(rejections.length === 0, `rejected: ${rejections.map(String).join("; ")}`);
		check(warnings.some((line) => line.includes("stale")), `said nothing: ${JSON.stringify(warnings)}`);
		check(!bench.requests().some((r) => r.hook_event_name === "wake"), "asked for mail through a stale ctx");

		// It stopped watching: mail landing later, even with a ctx that answers, starts nothing.
		ctx.isIdle = () => true;
		fs.writeFileSync(path.join(inbox, "m2.md"), "x");
		await sleep(300);
		check(record.sent.length === 0, `kept watching after the ctx went stale: ${JSON.stringify(record.sent)}`);
	} finally {
		process.off("unhandledRejection", onRejection);
		bench.done();
	}
});

await test("only pi's own TUI gets a mailbox: a print, json or rpc session (an Archon node) reports nothing to benchd", async () => {
	const bench = fakeBench();
	try {
		for (const mode of ["print", "json", "rpc"]) {
			bench.answer({ handle: "h", inbox: path.join(bench.dir, `inbox-${mode}`), rule: "a rule", context: "mail" });
			const { record, ctx, messages } = started();
			ctx.mode = mode;
			await record.handlers.get("session_start")({}, ctx);
			check(bench.requests().length === 0, `${mode}: reported ${JSON.stringify(bench.requests())}`);
			check(!fs.existsSync(path.join(bench.dir, `inbox-${mode}`)), `${mode}: watched an inbox`);
			check(messages[0] === "bench v1: no bench mailbox for this session", `${mode}: said ${JSON.stringify(messages)}`);
			check((await record.handlers.get("context")({ messages: [user("go")] }, ctx)) === undefined, `${mode}: injected`);
			check(record.handlers.get("before_agent_start")({ systemPrompt: "base" }, ctx) === undefined, `${mode}: ruled`);
			await record.handlers.get("agent_settled")({}, ctx);
			check(record.sent.length === 0, `${mode}: started a turn`);
		}
	} finally {
		bench.done();
	}
});

await test("no bench on PATH is silence: no mailbox, no throw, no injection", async () => {
	process.env.BENCH = path.join(os.tmpdir(), "no-such-bench-binary");
	const { record, ctx, messages } = started();
	await record.handlers.get("session_start")({}, ctx);
	check(messages[0] === "bench v1: no bench mailbox for this session", `said ${messages[0]}`);
	check((await record.handlers.get("context")({ messages: [user("go")] }, ctx)) === undefined, "injected");
	await record.handlers.get("agent_settled")({}, ctx);
	check(record.sent.length === 0, "sent a turn");
});

await test("the standing rule benchd gives is in the system prompt of every run", async () => {
	const bench = fakeBench();
	try {
		bench.answer({ handle: "h", rule: "Bench mail reaches you as a line." });
		const { record, ctx } = started();
		const before = record.handlers.get("before_agent_start");
		check(before({ systemPrompt: "base" }, ctx) === undefined, "a rule before session_start");
		await record.handlers.get("session_start")({}, ctx);
		for (const run of [1, 2]) {
			const result = before({ systemPrompt: "base" }, ctx);
			check(result?.systemPrompt === "base\n\nBench mail reaches you as a line.", `run ${run}: ${JSON.stringify(result)}`);
		}
	} finally {
		bench.done();
	}
});

await test("/bench says the same as session_start", async () => {
	const bench = fakeBench();
	try {
		bench.answer({ handle: "helm-a1b2" });
		const { record, ctx, messages } = started();
		await record.handlers.get("session_start")({}, ctx);
		await record.commands.get("bench").handler("", ctx);
		check(messages.length === 2 && messages[0] === messages[1], JSON.stringify(messages));
	} finally {
		bench.done();
	}
});

// ── The mutilated-pi cases. Each one must leave the factory returning normally. ──────────

await test("a pi missing sendUserMessage still loads and keeps reporting", () => {
	const { pi, record } = recordingPi();
	delete pi.sendUserMessage;
	const warnings = capturingStderr(() => factory(pi));
	check(record.handlers.has("context"), "lost the context handler");
	check(warnings.some((line) => line.includes("sendUserMessage")), JSON.stringify(warnings));
});

await test("one throwing registration does not take its siblings with it", () => {
	const { pi, record } = recordingPi({
		registerCommand() {
			throw new Error("mutilated");
		},
	});
	capturingStderr(() => factory(pi));
	check(record.handlers.has("session_start"), "lost the handlers");
	check(record.commands.size === 0, "registered through a throwing method");
});

await test("a pi whose every method throws, or that is nothing at all, leaves the factory returning", () => {
	const boom = () => {
		throw new Error("mutilated");
	};
	const warnings = capturingStderr(() => factory({ on: boom, registerCommand: boom, sendUserMessage: boom }));
	check(warnings.every((line) => line.startsWith("[bench]")), JSON.stringify(warnings));
	capturingStderr(() => factory({}));
	capturingStderr(() => factory(undefined));
	capturingStderr(() => factory(null));
});

console.log(failures === 0 ? "# all unit checks passed" : `# ${failures} unit check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
