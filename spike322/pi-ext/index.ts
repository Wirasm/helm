/**
 * SPIKE #322 — throwaway. A pi extension that holds NO copy of the mailbox convention.
 *
 * It imports `bench-mail-core.mjs` — the same module `spike322/bench-mail` (the CLI) and
 * `spike322/hook.mjs` (the Claude Code hook) import. If this loads inside a real pi, through
 * the SYMLINK pi extensions are installed as, then `AGENTS.md`'s standing carve-out —
 *
 *   "there is no shared module because pi loads a .ts extension and a hook is a standalone
 *    script — so any change to the address scheme, the notice or the on-disk shape has to be
 *    made in both"
 *
 * — is false for the two JavaScript halves, and the duplication it defends is optional.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
// @ts-ignore — a plain .mjs sibling; the spike is about whether node resolves it, not types.
import { mailRoot, peers, slug, suiteName } from "../bench-mail-core.mjs";

export default function (pi: ExtensionAPI): void {
	const root = mailRoot();
	console.error(`[spike322] SHARED MODULE LOADED. root=${root} suite="${suiteName()}" slug("A B")=${slug("A B")}`);
	try {
		pi.registerCommand("spike322", {
			description: "spike #322 — prove one module serves pi and the hook",
			handler: async (_args: string, ctx: any) => {
				const rows = peers(root, "");
				const text = `spike322: root=${root}\n${rows.join("\n") || "  (no mailboxes)"}`;
				if (typeof ctx?.ui?.notify === "function") ctx.ui.notify(text, "info");
				else console.error(text);
			},
		});
	} catch (error) {
		console.error(`[spike322] registerCommand failed: ${String(error)}`);
	}
}
