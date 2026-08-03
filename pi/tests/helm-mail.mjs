/**
 * helm-mail unit harness — a fake pi, no pi process, no model, no credits.
 *
 * Two things are tested here that no live harness can reach:
 *
 *   1. A deliberately MUTILATED pi — methods missing, methods throwing, nothing at all.
 *      On pi 0.83.0 a factory that throws exits the whole CLI, so "the factory is total"
 *      is the single property most worth testing, and only this harness can test it.
 *
 *   2. The mailbox convention itself, as behaviour rather than as prose: consumed exactly
 *      once, the wake cap holds, and the notice does not carry the body. That last one is
 *      the security property, and an assertion is the only thing that keeps it true.
 *
 * Every test runs against a fresh HELM_MAIL_DIR under the system temp dir. The operator's
 * real mailbox is never touched, and nothing here depends on what is on this machine.
 *
 * Usage: node pi/tests/helm-mail.mjs <path-to-extension-index.ts>
 */

import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const extensionPath = process.argv[2];
if (!extensionPath) {
	console.error("usage: node helm-mail.mjs <path-to-extension-index.ts>");
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
	try {
		await run();
	} catch (error) {
		fail(`threw ${error instanceof Error ? error.stack : String(error)}`);
		return;
	}
	ok(name);
}

// ── the fakes ────────────────────────────────────────────────────────────────────────────

/** A recording pi that accepts everything the extension might register. */
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

/** A ctx whose ui.notify records instead of drawing. */
function recordingCtx(sessionId = "aaaabbbb-1111", cwd = "/tmp/helm-mail-test-cwd") {
	const messages = [];
	return {
		ctx: {
			ui: { notify: (message) => messages.push(message) },
			cwd,
			sessionManager: { getSessionId: () => sessionId, getCwd: () => cwd },
			isIdle: () => true,
		},
		messages,
	};
}

/** Run body with console.error captured, so a degradation warning is assertable. */
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

const roots = [];

/** A fresh mailbox root for one test. Read by the extension when the factory runs. */
function freshRoot() {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "helm-mail-test-"));
	roots.push(root);
	process.env.HELM_MAIL_DIR = root;
	return root;
}

/**
 * Put a message in a mailbox the way a NON-pi sender would — by writing the file. That is
 * the convention under test; going through the extension's own send would only prove it
 * agrees with itself.
 */
function deliver(root, to, { from = "someone-else", subject = "a subject", body = "a body" } = {}) {
	const dir = path.join(root, to);
	fs.mkdirSync(path.join(dir, "read"), { recursive: true });
	const id = `${Date.now()}-${randomBytes(3).toString("hex")}`;
	fs.writeFileSync(path.join(dir, `${id}.json`), JSON.stringify({ id, from, to, subject, body, sentAt: Date.now() }));
	return id;
}

function queuedIn(dir) {
	return fs
		.readdirSync(dir)
		.filter((name) => name.endsWith(".json") && name !== "owner.json" && !name.startsWith("."));
}

const extension = await import(extensionPath);
const factory = extension.default;

if (typeof factory !== "function") {
	console.log("not ok - extension does not default-export a factory function");
	process.exit(1);
}

/** Install against a fully-capable pi, and start a session. Returns everything to assert on. */
function started(options = {}) {
	const root = options.root ?? freshRoot();
	const { pi, record } = recordingPi(options.overrides);
	factory(pi);
	const { ctx, messages } = recordingCtx(options.sessionId, options.cwd);
	const warnings = capturingStderr(() => record.handlers.get("session_start")({ reason: "startup" }, ctx));
	const handle = /handle: (\S+)/.exec(messages[0] ?? "")?.[1];
	return { root, pi, record, ctx, messages, warnings, handle, dir: handle && path.join(root, handle) };
}

// ── registration ─────────────────────────────────────────────────────────────────────────

await test("registers session_start, agent_settled and the /helm-mail command", () => {
	freshRoot();
	const { pi, record } = recordingPi();
	factory(pi);
	check(record.handlers.has("session_start"), "no session_start handler");
	check(record.handlers.has("agent_settled"), "no agent_settled handler — pi's rung 4 is not wired");
	check(record.commands.has("helm-mail"), "no helm-mail command");
});

await test("session_start claims a mailbox and reports it", () => {
	const s = started();
	check(/^helm-mail v/.test(s.messages[0] ?? ""), `unexpected report: ${s.messages[0]}`);
	check(Boolean(s.handle), `report named no handle: ${s.messages[0]}`);
	check(fs.existsSync(path.join(s.dir, "owner.json")), "claimed no owner.json");
	const owner = JSON.parse(fs.readFileSync(path.join(s.dir, "owner.json"), "utf8"));
	check(owner.runtime === "pi", `owner.runtime was ${owner.runtime}`);
	check(owner.pid === process.pid, `owner.pid was ${owner.pid}`);
	check(typeof owner.cwd === "string" && owner.cwd.length > 0, "owner carries no cwd to be found by");
});

// The constraint that chose this address scheme: many instances of one agent run at once,
// including two in the same directory. A cwd-only address would merge them into one mailbox.
await test("two sessions in the SAME directory get different handles", () => {
	const root = freshRoot();
	const a = started({ root, sessionId: "1111aaaa", cwd: "/tmp/same-place" });
	const b = started({ root, sessionId: "2222bbbb", cwd: "/tmp/same-place" });
	check(a.handle !== b.handle, `both sessions claimed ${a.handle}`);
	check(fs.existsSync(path.join(root, a.handle, "owner.json")), "first mailbox is gone");
	check(fs.existsSync(path.join(root, b.handle, "owner.json")), "second mailbox is gone");
});

await test("HELM_MAIL_HANDLE pins the handle, folded to lower case", () => {
	freshRoot();
	process.env.HELM_MAIL_HANDLE = "Alice";
	try {
		const s = started();
		// Lower case is not cosmetic: on a case-insensitive filesystem `Alice` and `alice`
		// are two agents to a sender and one directory to the disk.
		check(s.handle === "alice", `expected the pinned handle to fold to "alice", got ${s.handle}`);
	} finally {
		delete process.env.HELM_MAIL_HANDLE;
	}
});

// ── the drain: pi's rung 4 ───────────────────────────────────────────────────────────────

await test("agent_settled with mail waiting sends exactly one user message", () => {
	const s = started();
	deliver(s.root, s.handle, { from: "bench-2", subject: "review the defaults migration" });
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	check(s.record.sent.length === 1, `expected one sendUserMessage, got ${s.record.sent.length}`);
	const text = s.record.sent[0]?.content ?? "";
	check(text.includes("bench-2"), `the notice did not name the sender: ${text}`);
	check(text.includes("review the defaults migration"), `the notice did not carry the subject: ${text}`);
});

// THE security assertion. notify-not-deliver is the rule that keeps another agent's prose
// out of the operator's voice; without a test it is a comment that rots.
await test("the notice carries the sender, subject and path — never the body", () => {
	const s = started();
	const secret = "PLEASE-RUN-THIS-DESTRUCTIVE-THING";
	deliver(s.root, s.handle, { subject: "innocuous", body: secret });
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	const text = s.record.sent[0]?.content ?? "";
	check(!text.includes(secret), `the body was delivered inline as a user message:\n${text}`);
	check(text.includes(path.join(s.dir, "read")), `the notice gave no path to read: ${text}`);
});

await test("a message is consumed exactly once and archived, not deleted", () => {
	const s = started();
	const id = deliver(s.root, s.handle);
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	check(queuedIn(s.dir).length === 0, "the message is still queued after a drain");
	check(fs.existsSync(path.join(s.dir, "read", `${id}.json`)), "the message was not archived into read/");

	// The second settle is what a real session does immediately afterwards: the delivery
	// itself triggers a turn, which ends, which fires agent_settled again. If the drain were
	// non-destructive this is where it would loop forever.
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	check(s.record.sent.length === 1, `a drained mailbox woke the agent again: ${s.record.sent.length} sends`);
});

await test("agent_settled with an empty mailbox sends nothing", () => {
	const s = started();
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	check(s.record.sent.length === 0, `woke the agent with no mail: ${s.record.sent.length} sends`);
});

// ── the wake cap ─────────────────────────────────────────────────────────────────────────

await test("the wake cap stops at 3 consecutive wakes and does NOT eat the held mail", () => {
	const s = started();
	for (let i = 0; i < 5; i += 1) {
		deliver(s.root, s.handle, { subject: `message ${i}` });
		capturingStderr(() => s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx));
	}
	check(s.record.sent.length === 3, `expected the cap to hold at 3 wakes, got ${s.record.sent.length}`);
	check(queuedIn(s.dir).length === 2, `held mail was eaten: ${queuedIn(s.dir).length} still queued, expected 2`);
});

await test("the cap says on stderr that mail is being held, rather than going quiet", () => {
	const s = started();
	let lines = [];
	for (let i = 0; i < 4; i += 1) {
		deliver(s.root, s.handle, { subject: `message ${i}` });
		lines = capturingStderr(() => s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx));
	}
	check(
		lines.some((line) => line.includes("held") && line.includes("[helm-mail]")),
		`the cap held mail with no attributable notice: ${JSON.stringify(lines)}`,
	);
});

await test("a quiet drain resets the cap, so a real conversation is never permanently capped", () => {
	const s = started();
	for (let i = 0; i < 4; i += 1) {
		deliver(s.root, s.handle, { subject: `message ${i}` });
		capturingStderr(() => s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx));
	}
	check(s.record.sent.length === 3, "precondition: expected to be capped");

	// Drain the held mail by hand, then settle quiet — that is the reset.
	for (const name of queuedIn(s.dir)) fs.rmSync(path.join(s.dir, name));
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);

	deliver(s.root, s.handle, { subject: "after the reset" });
	s.record.handlers.get("agent_settled")({ type: "agent_settled" }, s.ctx);
	check(s.record.sent.length === 4, `the cap never reset: ${s.record.sent.length} sends`);
});

// ── refusing to eat mail it cannot deliver ───────────────────────────────────────────────

await test("a pi that cannot sendUserMessage keeps the mail queued rather than consuming it", () => {
	const root = freshRoot();
	const { pi, record } = recordingPi();
	delete pi.sendUserMessage;
	capturingStderr(() => factory(pi));
	const { ctx, messages } = recordingCtx();
	capturingStderr(() => record.handlers.get("session_start")({ reason: "startup" }, ctx));
	const handle = /handle: (\S+)/.exec(messages[0] ?? "")?.[1];
	deliver(root, handle);
	const lines = capturingStderr(() => record.handlers.get("agent_settled")({ type: "agent_settled" }, ctx));
	check(queuedIn(path.join(root, handle)).length === 1, "consumed mail it had no way to deliver");
	check(
		lines.some((line) => line.includes("cannot deliver")),
		`dropped delivery with no notice: ${JSON.stringify(lines)}`,
	);
});

// ── reaping ──────────────────────────────────────────────────────────────────────────────

await test("a dead agent's empty mailbox is reaped, so a sender cannot address a corpse", () => {
	const root = freshRoot();
	const dead = path.join(root, "dead-9999");
	fs.mkdirSync(path.join(dead, "read"), { recursive: true });
	// pid 2^22 is above every real pid on macOS and Linux, so it is reliably not running.
	fs.writeFileSync(
		path.join(dead, "owner.json"),
		JSON.stringify({ handle: "dead-9999", runtime: "pi", pid: 4194303, sessionId: "x", cwd: "/tmp", claimedAt: 1 }),
	);
	started({ root });
	check(!fs.existsSync(dead), "a dead, empty mailbox survived the reaper");
});

await test("a dead agent's mailbox is KEPT while it still holds mail", () => {
	const root = freshRoot();
	const dead = path.join(root, "dead-8888");
	fs.mkdirSync(path.join(dead, "read"), { recursive: true });
	fs.writeFileSync(
		path.join(dead, "owner.json"),
		JSON.stringify({ handle: "dead-8888", runtime: "pi", pid: 4194303, sessionId: "x", cwd: "/tmp", claimedAt: 1 }),
	);
	deliver(root, "dead-8888");
	started({ root });
	check(fs.existsSync(dead), "unread mail was destroyed with its dead mailbox");
});

await test("a live agent's mailbox and a corrupt owner.json are both left alone", () => {
	const root = freshRoot();
	const live = path.join(root, "live-7777");
	fs.mkdirSync(path.join(live, "read"), { recursive: true });
	fs.writeFileSync(
		path.join(live, "owner.json"),
		JSON.stringify({ handle: "live-7777", runtime: "pi", pid: process.pid, sessionId: "x", cwd: "/tmp", claimedAt: 1 }),
	);
	const corrupt = path.join(root, "corrupt-6666");
	fs.mkdirSync(path.join(corrupt, "read"), { recursive: true });
	fs.writeFileSync(path.join(corrupt, "owner.json"), "{ not json");
	started({ root });
	check(fs.existsSync(live), "reaped a mailbox whose owner is alive");
	check(fs.existsSync(corrupt), "reaped a mailbox it could not read — reaping must be conservative");
});

// ── the command ──────────────────────────────────────────────────────────────────────────

await test("/helm-mail with no args reports status", async () => {
	const s = started();
	const c = recordingCtx();
	await s.record.commands.get("helm-mail").handler("", c.ctx);
	check(/^helm-mail v/.test(c.messages[0] ?? ""), `unexpected status: ${c.messages[0]}`);
});

await test("/helm-mail send puts a message in a peer's mailbox", async () => {
	const root = freshRoot();
	const peer = started({ root, sessionId: "cccc3333", cwd: "/tmp/peer-place" });
	const me = started({ root, sessionId: "dddd4444", cwd: "/tmp/my-place" });
	const c = recordingCtx();
	await me.record.commands.get("helm-mail").handler(`send ${peer.handle} the build is red on development`, c.ctx);
	const waiting = queuedIn(peer.dir);
	check(waiting.length === 1, `expected one message in the peer's mailbox, got ${waiting.length}`);
	const message = JSON.parse(fs.readFileSync(path.join(peer.dir, waiting[0]), "utf8"));
	check(message.from === me.handle, `message.from was ${message.from}, expected ${me.handle}`);
	check(message.body.includes("build is red"), `message.body was ${message.body}`);
});

await test("/helm-mail send to a handle with no mailbox refuses and says so", async () => {
	const s = started();
	const c = recordingCtx();
	await s.record.commands.get("helm-mail").handler("send nobody-here hello", c.ctx);
	check(
		(c.messages[0] ?? "").includes("could not send"),
		`a send to a nonexistent mailbox did not refuse visibly: ${c.messages[0]}`,
	);
});

await test("/helm-mail list names every mailbox with the cwd that tells them apart", async () => {
	const root = freshRoot();
	const peer = started({ root, sessionId: "eeee5555", cwd: "/tmp/auth-worktree" });
	const c = recordingCtx();
	await peer.record.commands.get("helm-mail").handler("list", c.ctx);
	check((c.messages[0] ?? "").includes(peer.handle), `list did not name ${peer.handle}: ${c.messages[0]}`);
	check((c.messages[0] ?? "").includes("/tmp/auth-worktree"), `list gave no cwd to choose by: ${c.messages[0]}`);
});

await test("/helm-mail read drains without waking a turn", async () => {
	const s = started();
	deliver(s.root, s.handle, { from: "bench-3", subject: "look at this" });
	const c = recordingCtx();
	await s.record.commands.get("helm-mail").handler("read", c.ctx);
	check(s.record.sent.length === 0, "a human-driven read woke a turn as well as reporting");
	check((c.messages[0] ?? "").includes("bench-3"), `read did not report the message: ${c.messages[0]}`);
	check(queuedIn(s.dir).length === 0, "read left the message queued");
});

// ── never silent ─────────────────────────────────────────────────────────────────────────

await test("a ctx with no usable ui falls back to stderr rather than going quiet", () => {
	freshRoot();
	const { pi, record } = recordingPi();
	factory(pi);
	for (const ctx of [{}, { ui: {} }]) {
		const printed = capturingStderr(() => record.handlers.get("session_start")({ reason: "startup" }, ctx));
		check(
			printed.some((line) => line.startsWith("helm-mail v")),
			`session_start reported nothing for ctx ${JSON.stringify(ctx)}: ${JSON.stringify(printed)}`,
		);
	}
});

await test("a mailbox root that cannot be created is reported, not swallowed", () => {
	// A path under a regular file can never be created, on every platform this runs on.
	const blocker = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "helm-mail-block-")), "a-file");
	fs.writeFileSync(blocker, "not a directory");
	process.env.HELM_MAIL_DIR = blocker;
	const { pi, record } = recordingPi();
	factory(pi);
	const { ctx } = recordingCtx();
	const warnings = capturingStderr(() => record.handlers.get("session_start")({ reason: "startup" }, ctx));
	check(
		warnings.some((line) => line.includes("unreachable by mail")),
		`a session with no mailbox said nothing: ${JSON.stringify(warnings)}`,
	);
});

// ── the mutilated-pi cases. Each one must leave the factory returning normally. ───────────

await test("a pi missing registerCommand still loads, keeps the handlers, and says what is missing", () => {
	freshRoot();
	const { pi, record } = recordingPi();
	delete pi.registerCommand;
	const warnings = capturingStderr(() => factory(pi));
	check(record.handlers.has("session_start"), "lost session_start when a sibling method went missing");
	check(record.handlers.has("agent_settled"), "lost agent_settled when a sibling method went missing");
	check(record.commands.size === 0, "registered a command through a missing method");
	check(
		warnings.some((line) => line.includes("registerCommand")),
		`no warning named the missing method: ${JSON.stringify(warnings)}`,
	);
});

// One throwing method among healthy siblings. Distinct from both neighbours: "missing" never
// reaches step() at all, and "everything throws" cannot tell per-capability isolation from
// one shared try. Without this, collapsing the step() calls into one would pass.
await test("one throwing registration does not take its healthy siblings with it", () => {
	freshRoot();
	const { pi, record } = recordingPi({
		registerCommand() {
			throw new Error("mutilated");
		},
	});
	const warnings = capturingStderr(() => factory(pi));
	check(record.handlers.has("session_start"), "lost session_start when a sibling step threw");
	check(record.handlers.has("agent_settled"), "lost agent_settled when a sibling step threw");
	check(record.commands.size === 0, "registered a command through a throwing method");
	check(
		warnings.filter((line) => line.includes("command")).length === 1,
		`expected exactly one warning for the failed step: ${JSON.stringify(warnings)}`,
	);
});

await test("a pi whose every method throws still leaves the factory returning normally", () => {
	freshRoot();
	const boom = () => {
		throw new Error("mutilated");
	};
	const warnings = capturingStderr(() =>
		factory({ on: boom, registerCommand: boom, sendUserMessage: boom }),
	);
	check(warnings.length >= 2, `expected one warning per failed registration, got ${warnings.length}`);
	check(
		warnings.every((line) => line.startsWith("[helm-mail]")),
		`warnings are not attributable: ${JSON.stringify(warnings)}`,
	);
});

await test("a pi with no methods at all still leaves the factory returning normally", () => {
	freshRoot();
	capturingStderr(() => factory({}));
});

await test("a pi that is not an object at all still leaves the factory returning normally", () => {
	freshRoot();
	capturingStderr(() => factory(undefined));
	capturingStderr(() => factory(null));
});

await test("HELM_MAIL_OFF makes it register nothing", () => {
	freshRoot();
	process.env.HELM_MAIL_OFF = "1";
	let record;
	try {
		const fake = recordingPi();
		record = fake.record;
		factory(fake.pi);
	} finally {
		delete process.env.HELM_MAIL_OFF;
	}
	check(record.handlers.size === 0, "registered a handler while switched off");
	check(record.commands.size === 0, "registered a command while switched off");
});

for (const root of roots) fs.rmSync(root, { recursive: true, force: true });

console.log(failures === 0 ? "# all unit checks passed" : `# ${failures} unit check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
