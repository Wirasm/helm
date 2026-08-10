// SPIKE #322 — throwaway. The mailbox convention as ONE module, exported.
//
// Every function below is lifted verbatim from `hooks/helm-mail.mjs` (which is itself the
// hand-maintained twin of `pi/extensions/helm-mail/index.ts`). Nothing is re-derived: the
// point of the spike is to find out whether the *same* rules can have one home that the hook,
// the pi extension and a CLI all reach — not to write a better mailbox.
//
// The `send` half is NOT lifted from the hook, because the hook has no send. It is lifted from
// `pi/extensions/helm-mail/index.ts:562` (`send`), which is the only executable send in the
// repo besides Swift's `Mailbox.deliver`.

import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const READ_DIR = "read";
export const OWNER_FILE = "owner.json";
export const ROOT_ENV = "HELM_MAIL_DIR";
export const HANDLE_ENV = "HELM_MAIL_HANDLE";
export const SUITE_ENV = "HELM_DEFAULTS_SUITE";
export const CANONICAL_DOMAIN = "com.wirasm.helm";
export const LEGACY_DOMAIN = "helm";
export const OPERATOR_SENDER = "operator";
export const SUBJECT_MAX = 80;
export const FROM_MAX = 64;

export function suiteName(env = process.env) {
	const raw = (env[SUITE_ENV] ?? "").trim();
	if (!raw) return "";
	if (raw === CANONICAL_DOMAIN || raw === LEGACY_DOMAIN) return "";
	if (raw.includes("/")) return "";
	return raw;
}

export function mailRoot(env = process.env) {
	const override = env[ROOT_ENV];
	if (override && override.trim()) return path.resolve(override.trim());
	const suite = suiteName(env);
	return path.join(os.homedir(), ".helm", suite ? `mail-${suite}` : "mail");
}

export function slug(text) {
	const cleaned = String(text ?? "")
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "");
	return cleaned || "agent";
}

export function tail(id, width) {
	return id.slice(-width).replace(/^-+|-+$/g, "");
}

export function pidAlive(pid) {
	if (!Number.isInteger(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error?.code === "EPERM";
	}
}

export function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8"));
	} catch {
		return undefined;
	}
}

export function writeAtomic(file, data) {
	const temp = path.join(path.dirname(file), `.tmp-${randomBytes(6).toString("hex")}`);
	fs.writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
	fs.renameSync(temp, file);
}

export function allHandles(root) {
	try {
		return fs
			.readdirSync(root, { withFileTypes: true })
			.filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
			.map((entry) => entry.name);
	} catch {
		return [];
	}
}

export function queued(dir) {
	try {
		return fs
			.readdirSync(dir)
			.filter((name) => name.endsWith(".json") && name !== OWNER_FILE && !name.startsWith("."))
			.sort();
	} catch {
		return [];
	}
}

export function heldByAnother(root, handle, mine) {
	const owner = readJson(path.join(root, handle, OWNER_FILE));
	if (!owner || typeof owner.pid !== "number") return false;
	if (owner.retiredAt) return false;
	if (owner.sessionId && owner.sessionId === mine) return false;
	return pidAlive(owner.pid);
}

export function deriveHandle(root, cwd, sessionId, identityPid = process.ppid) {
	const pinned = process.env[HANDLE_ENV];
	if (pinned && pinned.trim() && slug(pinned) !== OPERATOR_SENDER) return slug(pinned);
	const where = slug(path.basename(cwd || process.cwd()));
	const full = slug(sessionId || String(identityPid));
	const widths = [4, 6, 8].filter((width) => width < full.length);
	for (const which of [...widths.map((width) => tail(full, width)), full]) {
		if (!which) continue;
		const handle = `${where}-${which}`;
		if (!heldByAnother(root, handle, sessionId)) return handle;
	}
	return `${where}-${full}-${process.pid}`;
}

export function oneLine(text, max, missing) {
	const collapsed = String(text ?? "")
		.replace(/\s+/g, " ")
		.trim();
	if (!collapsed) return missing;
	return collapsed.length > max ? `${collapsed.slice(0, max - 1)}…` : collapsed;
}

export function consume(dir, names) {
	const taken = [];
	for (const name of names) {
		const from = path.join(dir, name);
		const to = path.join(dir, READ_DIR, name);
		const message = readJson(from);
		try {
			fs.renameSync(from, to);
		} catch {
			continue;
		}
		if (message) taken.push({ message, file: to });
	}
	return taken;
}

export function mineIn(root, sessionId, cwd, identityPid) {
	for (const handle of allHandles(root)) {
		const owner = readJson(path.join(root, handle, OWNER_FILE));
		if (owner?.sessionId && owner.sessionId === sessionId) return handle;
	}
	return deriveHandle(root, cwd, sessionId, identityPid);
}

export function claim(root, { handle, runtime, pid, sessionId, cwd }) {
	const dir = path.join(root, handle);
	fs.mkdirSync(path.join(dir, READ_DIR), { recursive: true });
	writeAtomic(path.join(dir, OWNER_FILE), {
		handle,
		runtime,
		pid,
		sessionId,
		cwd,
		claimedAt: Date.now(),
	});
	return { handle, dir };
}

/**
 * Put a message in someone's mailbox — `pi/extensions/helm-mail/index.ts:562`, verbatim in
 * behaviour, with ONE change that is the whole of assumption 6: `from` is not a free parameter.
 * The caller states who it is and the module refuses the reserved name.
 */
export function send(root, { to, from, subject, body }) {
	if (slug(from) === OPERATOR_SENDER) {
		throw new Error(`"${OPERATOR_SENDER}" is reserved — helm's own canvas notes send as that, and nothing else may`);
	}
	const dir = path.join(root, to);
	if (!fs.existsSync(dir)) throw new Error(`no mailbox for "${to}" — run \`bench mail list\` to see who is reachable`);
	const owner = readJson(path.join(dir, OWNER_FILE));
	if (owner?.retiredAt) {
		throw new Error(`"${to}" has retired — that agent is gone and will not read this. Its archive is still in ${dir}`);
	}
	const message = {
		id: `${Date.now()}-${randomBytes(3).toString("hex")}`,
		from,
		to,
		subject: oneLine(subject, SUBJECT_MAX, "(no subject)"),
		body: String(body ?? ""),
		sentAt: Date.now(),
	};
	writeAtomic(path.join(dir, `${message.id}.json`), message);
	return message;
}

export function peers(root, mine) {
	const rows = [];
	for (const handle of allHandles(root)) {
		const owner = readJson(path.join(root, handle, OWNER_FILE));
		const waiting = queued(path.join(root, handle)).length;
		const mark = handle === mine ? " (this session)" : "";
		if (!owner) {
			rows.push(`  ${handle} — no owner.json${mark}`);
			continue;
		}
		let alive;
		if (owner.retiredAt) alive = " [retired]";
		else if (pidAlive(owner.pid)) alive = "";
		else alive = " [dead]";
		const mail = waiting > 0 ? `, ${waiting} waiting` : "";
		rows.push(`  ${handle} — ${owner.runtime}, pid ${owner.pid}${alive}, ${owner.cwd}${mail}${mark}`);
	}
	return rows;
}
