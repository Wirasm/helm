#!/usr/bin/env bash
# The test command for helm's pi extensions. Four harnesses, none of which calls a model.
#
#   typecheck  tsc --noEmit against the pi that is actually installed.  THE UPGRADE ALARM.
#   unit       node + a fake pi, including a deliberately mutilated one. Milliseconds.
#   rpc        a real `pi --mode rpc`; asserts the extension loads and its UI call surfaces.
#   pty        a real TUI under `script`; asserts pi reaches a normal prompt.
#
# Usage: bash pi/test.sh [typecheck|unit|rpc|pty|all]   (default: all)
#
# Every harness SKIPS rather than fails when its toolchain is absent, so this can sit in
# helm's gate on a machine with no node. A skip is printed; it is never silent.
#
# Verified against pi 0.83.0 on 2026-08-02.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSIONS_DIR="$ROOT/extensions"
FAILURES=0

say()  { printf '%s\n' "$*"; }
skip() { printf 'skip: %s\n' "$*"; }
bad()  { printf 'not ok - %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# The installed pi package. Overridable so this can be pointed at a candidate upgrade.
PI_PACKAGE_DIR=${PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

have_pi_package() { [ -f "$PI_PACKAGE_DIR/package.json" ]; }

pi_version() {
	node -p "require('$PI_PACKAGE_DIR/package.json').version" 2>/dev/null || printf 'unknown'
}

# A temp workspace with the extensions copied in and pi's OWN type packages symlinked
# beside them. Nothing is vendored: the types are always whatever pi is installed right
# now, which is the entire point of the typecheck. Borrowed from firstmate's
# tests/fm-pi-primary-types.test.sh.
make_fixture() {
	local fixture=$1
	mkdir -p "$fixture/node_modules/@earendil-works" "$fixture/node_modules/@types"
	cp -R "$EXTENSIONS_DIR" "$fixture/extensions"
	ln -sfn "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
	ln -sfn "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
	ln -sfn "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
	ln -sfn "$PI_PACKAGE_DIR/node_modules/@types/node" "$fixture/node_modules/@types/node"
	printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
	cat >"$fixture/tsconfig.json" <<-'JSON'
		{
		  "compilerOptions": {
		    "allowImportingTsExtensions": true,
		    "module": "NodeNext",
		    "moduleResolution": "NodeNext",
		    "noEmit": true,
		    "skipLibCheck": true,
		    "strict": true,
		    "target": "ES2022",
		    "types": ["node"]
		  },
		  "include": ["extensions/**/*.ts"]
		}
	JSON
}

find_tsc() {
	if [ -n "${PI_TSC:-}" ]; then printf '%s' "$PI_TSC"; return 0; fi
	if [ -x "$ROOT/node_modules/.bin/tsc" ]; then printf '%s' "$ROOT/node_modules/.bin/tsc"; return 0; fi
	if command -v tsc >/dev/null 2>&1; then command -v tsc; return 0; fi
	return 1
}

# ── typecheck ────────────────────────────────────────────────────────────────────────────
# Why this matters more than it looks: measured on 0.83.0, subscribing to an event pi no
# longer has succeeds silently — pi.on() only pushes into a Map, so the handler simply never
# fires. Runtime cannot tell you. The typecheck is the ONLY place a removed event becomes
# visible, which is why extensions import the real ExtensionAPI instead of duck-typing it.
harness_typecheck() {
	command -v node >/dev/null 2>&1 || { skip "typecheck: node not found"; return 0; }
	command -v npm >/dev/null 2>&1 || { skip "typecheck: npm not found"; return 0; }
	have_pi_package || { skip "typecheck: no installed pi at $PI_PACKAGE_DIR"; return 0; }

	local tsc
	if ! tsc=$(find_tsc); then
		skip "typecheck: no tsc — run 'npm install' in pi/ to get one"
		return 0
	fi
	for dep in node_modules/typebox node_modules/@earendil-works/pi-tui node_modules/@types/node; do
		[ -d "$PI_PACKAGE_DIR/$dep" ] || { bad "typecheck: installed pi is missing $dep"; return 0; }
	done

	local fixture
	fixture=$(mktemp -d "${TMPDIR:-/tmp}/helm-pi-typecheck.XXXXXX") || { bad "typecheck: mktemp failed"; return 0; }
	make_fixture "$fixture"
	if "$tsc" -p "$fixture/tsconfig.json"; then
		say "ok - extensions typecheck strictly against pi $(pi_version)"
	else
		bad "typecheck failed against pi $(pi_version) — an API we use has changed"
	fi
	rm -rf "$fixture"
}

# ── unit ─────────────────────────────────────────────────────────────────────────────────
harness_unit() {
	command -v node >/dev/null 2>&1 || { skip "unit: node not found"; return 0; }
	have_pi_package || { skip "unit: no installed pi at $PI_PACKAGE_DIR (typebox comes from it)"; return 0; }

	local fixture
	fixture=$(mktemp -d "${TMPDIR:-/tmp}/helm-pi-unit.XXXXXX") || { bad "unit: mktemp failed"; return 0; }
	make_fixture "$fixture"
	local status=0
	for extension in "$EXTENSIONS_DIR"/*/; do
		local name
		name=$(basename "$extension")
		[ -f "$ROOT/tests/$name.mjs" ] || { skip "unit: no tests/$name.mjs"; continue; }
		(cd "$fixture" && node "$ROOT/tests/$name.mjs" "$fixture/extensions/$name/index.ts") || status=1
	done
	[ "$status" -eq 0 ] || bad "unit checks failed"
	rm -rf "$fixture"
}

# ── rpc ──────────────────────────────────────────────────────────────────────────────────
# `--no-extensions` suppresses BOTH auto-discovery and settings.json entries (measured), so
# with an explicit `-e` this run sees exactly one extension no matter what the machine has
# installed. Nothing here reaches a model: an extension command invoked as a `/`-prefixed
# prompt is handled locally.
harness_rpc() {
	command -v pi >/dev/null 2>&1 || { skip "rpc: pi not on PATH"; return 0; }
	command -v node >/dev/null 2>&1 || { skip "rpc: node not found"; return 0; }

	local cwd out before
	before=$FAILURES
	cwd=$(mktemp -d "${TMPDIR:-/tmp}/helm-pi-rpc.XXXXXX") || { bad "rpc: mktemp failed"; return 0; }
	out="$cwd/out.jsonl"

	if ! (cd "$cwd" && printf '%s\n' '{"id":"1","type":"get_commands"}' |
		pi --mode rpc --no-session --no-extensions -e "$EXTENSIONS_DIR/helm-probe/index.ts" >"$out" 2>"$cwd/err"); then
		bad "rpc: pi exited nonzero with the extension loaded"
		sed 's/^/    /' "$cwd/err" >&2
		rm -rf "$cwd"
		return 0
	fi

	grep -q '"method":"notify"' "$out" ||
		bad "rpc: session_start produced no extension_ui_request notify frame"
	grep -q 'helm-probe v' "$out" ||
		bad "rpc: the notify frame did not carry the report"

	node -e '
		const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
		const found = lines.some((line) => {
			try {
				const frame = JSON.parse(line);
				return frame.command === "get_commands" && frame.data.commands.some((c) => c.name === "helm-probe");
			} catch { return false; }
		});
		process.exit(found ? 0 : 1);
	' "$out" || bad "rpc: /helm-probe is not in get_commands"

	# Only now, having proved the command is registered, invoke it — a `/name` prompt that
	# is NOT a registered command would be sent to the model, and this suite spends nothing.
	if (cd "$cwd" && printf '%s\n' '{"id":"1","type":"prompt","message":"/helm-probe"}' |
		pi --mode rpc --no-session --no-extensions -e "$EXTENSIONS_DIR/helm-probe/index.ts" >"$cwd/cmd.jsonl" 2>/dev/null); then
		grep -q '"type":"agent_start"' "$cwd/cmd.jsonl" &&
			bad "rpc: invoking /helm-probe started an agent turn — that would spend credits"
		[ "$(grep -c '"method":"notify"' "$cwd/cmd.jsonl")" -ge 2 ] ||
			bad "rpc: /helm-probe did not report"
	else
		bad "rpc: invoking /helm-probe exited nonzero"
	fi

	# The kill switch has to actually kill.
	if (cd "$cwd" && printf '%s\n' '{"id":"1","type":"get_commands"}' |
		HELM_PROBE_OFF=1 pi --mode rpc --no-session --no-extensions -e "$EXTENSIONS_DIR/helm-probe/index.ts" >"$cwd/off.jsonl" 2>/dev/null); then
		grep -q '"method":"notify"' "$cwd/off.jsonl" &&
			bad "rpc: HELM_PROBE_OFF did not switch the extension off"
	else
		bad "rpc: pi exited nonzero with the extension switched off"
	fi

	if [ "$FAILURES" -eq "$before" ]; then
		say "ok - loads under a real pi --mode rpc, reports, and switches off"
	fi
	rm -rf "$cwd"
}

# ── pty ──────────────────────────────────────────────────────────────────────────────────
# The one thing rpc cannot show: that a real interactive pi reaches a normal prompt with
# our extension loaded. `script` gives it a pty; stdin is /dev/null so pi renders and exits.
harness_pty() {
	command -v pi >/dev/null 2>&1 || { skip "pty: pi not on PATH"; return 0; }
	command -v script >/dev/null 2>&1 || { skip "pty: script not found"; return 0; }

	local cwd raw
	cwd=$(mktemp -d "${TMPDIR:-/tmp}/helm-pi-pty.XXXXXX") || { bad "pty: mktemp failed"; return 0; }
	raw="$cwd/pty.raw"

	(
		cd "$cwd" || exit 1
		if script --version 2>/dev/null | grep -qi util-linux; then
			script -q -c "pi --no-session --no-extensions -e '$EXTENSIONS_DIR/helm-probe/index.ts'" /dev/null
		else
			script -q /dev/null pi --no-session --no-extensions -e "$EXTENSIONS_DIR/helm-probe/index.ts"
		fi
	) >"$raw" 2>&1 </dev/null &
	local runner=$!

	# Bounded wait for the report to appear, then stop whatever is left. No `timeout`
	# dependency: helm's own tools take the same line, and a poll says what it waited for.
	local i=0
	while [ "$i" -lt 200 ]; do
		grep -q 'helm-probe v' "$raw" 2>/dev/null && break
		kill -0 "$runner" 2>/dev/null || break
		sleep 0.1
		i=$((i + 1))
	done
	kill "$runner" 2>/dev/null
	wait "$runner" 2>/dev/null
	pkill -f "helm-probe/index.ts" 2>/dev/null

	local screen
	screen=$(LC_ALL=C sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\x1b\\][^\x07]*\x07//g' "$raw" | tr -d '\r')
	if ! printf '%s' "$screen" | grep -q 'pi v'; then
		bad "pty: pi never rendered its banner — it did not reach a prompt"
	elif ! printf '%s' "$screen" | grep -q 'helm-probe v'; then
		bad "pty: pi reached a prompt but the extension never reported"
	else
		say "ok - a real TUI reaches a normal prompt with the extension loaded"
	fi
	rm -rf "$cwd"
}

case "${1:-all}" in
	typecheck) harness_typecheck ;;
	unit)      harness_unit ;;
	rpc)       harness_rpc ;;
	pty)       harness_pty ;;
	all)       harness_typecheck; harness_unit; harness_rpc; harness_pty ;;
	*)         say "usage: bash pi/test.sh [typecheck|unit|rpc|pty|all]"; exit 2 ;;
esac

if [ "$FAILURES" -ne 0 ]; then
	say "# $FAILURES check(s) failed"
	exit 1
fi
say "# pi extensions ok"
