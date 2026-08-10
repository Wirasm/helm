#!/usr/bin/env node
// SPIKE #322 — throwaway. The Claude Code hook half, holding NO copy of the convention.
// Same module as the CLI and the pi extension. Verbs kept identical to hooks/helm-mail.mjs.
import * as path from "node:path";
import { claim, consume, mailRoot, mineIn, queued } from "./bench-mail-core.mjs";

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
let input = {};
try {
	input = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
} catch {
	input = {};
}
const verb = process.argv[2];
const sessionId = input.session_id || process.env.CLAUDE_CODE_SESSION_ID || "";
const cwd = input.cwd || process.cwd();
if (!sessionId) process.exit(0);
const root = mailRoot();

if (verb === "claim") {
	const handle = mineIn(root, sessionId, cwd, process.ppid);
	claim(root, { handle, runtime: "claude", pid: process.ppid, sessionId, cwd });
	process.stderr.write(`[spike322-hook] SHARED MODULE claimed ${handle} in ${root}\n`);
	process.exit(0);
}
if (verb === "deliver") {
	const handle = mineIn(root, sessionId, cwd, process.ppid);
	const dir = path.join(root, handle);
	const waiting = queued(dir);
	if (waiting.length === 0) process.exit(0);
	const taken = consume(dir, waiting);
	process.stdout.write(`[spike322-hook] ${taken.length} message(s) for ${handle}\n`);
	for (const { message, file } of taken) process.stdout.write(`  from ${message.from} — ${message.subject}\n    ${file}\n`);
	process.exit(0);
}
process.exit(0);
