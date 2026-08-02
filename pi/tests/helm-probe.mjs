/**
 * helm-probe unit harness — a fake pi, no pi process, no model, no credits.
 *
 * The extension is a module that exports one function, so the cheapest possible test is to
 * import it and call that function with an object we control. That lets us do the thing no
 * live harness can: hand it a **deliberately mutilated** pi — methods missing, methods
 * throwing, nothing at all — and require that the factory still returns normally. On pi
 * 0.83.0 a factory that throws exits the whole CLI, so "the factory is total" is the single
 * property most worth testing, and this is the only harness that can test it directly.
 *
 * Borrowed in shape from firstmate's tests/fm-calm-pi-extension.test.sh, which drives its
 * extensions the same way.
 *
 * Usage: node pi/tests/unit.mjs <path-to-extension-index.ts>
 */

const extensionPath = process.argv[2];
if (!extensionPath) {
	console.error("usage: node unit.mjs <path-to-extension-index.ts>");
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
		fail(`threw ${error instanceof Error ? error.message : String(error)}`);
		return;
	}
	ok(name);
}

/** A recording pi that accepts everything the extension might register. */
function recordingPi(overrides = {}) {
	const record = { handlers: new Map(), commands: new Map(), tools: new Map() };
	const base = {
		on(event, handler) {
			record.handlers.set(event, handler);
		},
		registerCommand(name, options) {
			record.commands.set(name, options);
		},
		registerTool(tool) {
			record.tools.set(tool.name, tool);
		},
	};
	return { pi: { ...base, ...overrides }, record };
}

/** A ctx whose ui.notify records instead of drawing. */
function recordingCtx() {
	const messages = [];
	return { ctx: { ui: { notify: (message) => messages.push(message) } }, messages };
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

const extension = await import(extensionPath);
const factory = extension.default;

if (typeof factory !== "function") {
	console.log("not ok - extension does not default-export a factory function");
	process.exit(1);
}

await test("registers a session_start handler, the /helm-probe command and the helm_probe tool", () => {
	const { pi, record } = recordingPi();
	factory(pi);
	check(record.handlers.has("session_start"), "no session_start handler");
	check(record.commands.has("helm-probe"), "no helm-probe command");
	check(record.tools.has("helm_probe"), "no helm_probe tool");
});

await test("session_start reports through ctx.ui.notify", () => {
	const { pi, record } = recordingPi();
	factory(pi);
	const { ctx, messages } = recordingCtx();
	record.handlers.get("session_start")({ reason: "startup" }, ctx);
	check(messages.length === 1, `expected one notify, got ${messages.length}`);
	check(/^helm-probe v/.test(messages[0] ?? ""), `unexpected report: ${messages[0]}`);
});

await test("the command reports the same text as the handler", async () => {
	const { pi, record } = recordingPi();
	factory(pi);
	const { ctx, messages } = recordingCtx();
	await record.commands.get("helm-probe").handler("", ctx);
	check(messages.length === 1, `expected one notify, got ${messages.length}`);
	check(messages[0].includes("present:"), `report has no capability list: ${messages[0]}`);
});

await test("the tool executes and returns the report as text", async () => {
	const { pi, record } = recordingPi();
	factory(pi);
	const result = await record.tools.get("helm_probe").execute("call-1", {}, undefined, undefined, {});
	const text = result?.content?.[0]?.text ?? "";
	check(text.startsWith("helm-probe v"), `unexpected tool output: ${text}`);
});

await test("a ctx with no ui does not throw", () => {
	const { pi, record } = recordingPi();
	factory(pi);
	record.handlers.get("session_start")({ reason: "startup" }, {});
	record.handlers.get("session_start")({ reason: "startup" }, { ui: {} });
});

// ── The mutilated-pi cases. Each one must leave the factory returning normally. ──────────

await test("a pi missing registerTool still loads, keeps the rest, and says what is missing", () => {
	const { pi, record } = recordingPi();
	delete pi.registerTool;
	const warnings = capturingStderr(() => factory(pi));
	check(record.handlers.has("session_start"), "lost the handler when a sibling method went missing");
	check(record.commands.has("helm-probe"), "lost the command when a sibling method went missing");
	check(record.tools.size === 0, "registered a tool through a missing method");
	check(
		warnings.some((line) => line.includes("registerTool")),
		`no warning named the missing method: ${JSON.stringify(warnings)}`,
	);
});

await test("a pi whose every method throws still leaves the factory returning normally", () => {
	const boom = () => {
		throw new Error("mutilated");
	};
	const warnings = capturingStderr(() => factory({ on: boom, registerCommand: boom, registerTool: boom }));
	check(warnings.length >= 3, `expected one warning per failed registration, got ${warnings.length}`);
	check(
		warnings.every((line) => line.startsWith("[helm-probe]")),
		`warnings are not attributable: ${JSON.stringify(warnings)}`,
	);
});

await test("a pi with no methods at all still leaves the factory returning normally", () => {
	capturingStderr(() => factory({}));
});

await test("a pi that is not an object at all still leaves the factory returning normally", () => {
	capturingStderr(() => factory(undefined));
	capturingStderr(() => factory(null));
});

await test("HELM_PROBE_OFF makes it register nothing", () => {
	const { pi, record } = recordingPi();
	process.env.HELM_PROBE_OFF = "1";
	try {
		factory(pi);
	} finally {
		delete process.env.HELM_PROBE_OFF;
	}
	check(record.handlers.size === 0, "registered a handler while switched off");
	check(record.commands.size === 0, "registered a command while switched off");
	check(record.tools.size === 0, "registered a tool while switched off");
});

console.log(failures === 0 ? "# all unit checks passed" : `# ${failures} unit check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
