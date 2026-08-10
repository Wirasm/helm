#!/usr/bin/env bash
# The gate for pi extensions. Four harnesses, none of which calls a model.
#
#   typecheck  tsc --noEmit against the pi that is actually installed.  THE UPGRADE ALARM.
#   unit       node + a fake pi, including a deliberately mutilated one. Milliseconds.
#   rpc        a real `pi --mode rpc`; asserts the extension loads and its UI call surfaces.
#   pty        a real TUI under `script`; asserts pi reaches a normal prompt.
#
# Usage: bash <this-script> [typecheck|unit|rpc|pty|all]   (default: all)
#
# Run it from anywhere inside the project whose extensions are under test — it operates on
# THAT project, never on the skill directory it happens to live in, so it works unchanged in
# any repo that grows pi extensions. Layout it expects, overridable:
#
#   PI_EXT_DIR      extensions   (default: <git root>/pi/extensions)
#   PI_TESTS_DIR    unit tests   (default: the extensions dir's sibling `tests/`)
#   PI_PACKAGE_DIR  installed pi (default: `npm root -g`/@earendil-works/pi-coding-agent)
#   PI_TSC          a tsc        (default: <project>/pi/node_modules/.bin/tsc, then PATH)
#
# Deliberately NOT wired into a project's main build gate when that gate is another language's:
# this needs node and a tsc, and a contributor who never touches pi/ should not have to install
# a JS toolchain to make the repo go green. Run it when the extensions change.
#
# Every harness SKIPS rather than fails when its toolchain is absent, so this still runs
# usefully with only some of it installed. A skip is printed; it is never silent.
#
# Two of the harnesses start a REAL pi, which loads real extensions, which write real files.
# `sandbox` below points every root helm's conventions honour at a per-run temp directory, and
# `assert_real_state_untouched` proves it worked. Read that block before adding a harness.
#
# Verified against pi 0.83.0 on 2026-08-02.
set -u

# The project under test, derived from where this is RUN, never from where this file LIVES.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
EXTENSIONS_DIR=${PI_EXT_DIR:-"$PROJECT_ROOT/pi/extensions"}
TESTS_DIR=${PI_TESTS_DIR:-"$(dirname "$EXTENSIONS_DIR")/tests"}
FAILURES=0

say()  { printf '%s\n' "$*"; }
skip() { printf 'skip: %s\n' "$*"; }
bad()  { printf 'not ok - %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# The installed pi package. Overridable so this can be pointed at a candidate upgrade.
PI_PACKAGE_DIR=${PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# `pi` on PATH and the package `npm root -g` reports are two different questions, and they
# can disagree — a different active node under nvm/volta, or a non-npm install. When they
# do, typecheck would skip while rpc/pty run, and the upgrade alarm would be quietly off.
# Say so rather than let a lone `skip:` line pass for a full run.
have_pi_package() {
	if [ -f "$PI_PACKAGE_DIR/package.json" ]; then return 0; fi
	if have_cmd pi; then
		say "warning: pi is on PATH but its package is not at $PI_PACKAGE_DIR."
		say "         The typecheck cannot run. Set PI_PACKAGE_DIR to the installed package."
	fi
	return 1
}

pi_version() {
	node -p "require('$PI_PACKAGE_DIR/package.json').version" 2>/dev/null || printf 'unknown'
}

# Every temp directory this gate makes starts with this, and the guard below sweeps for it.
# One constant, because "what the gate is allowed to have created" is one question.
TEMP_PREFIX=pi-ext-

# A private temp dir named for the harness that owns it.
make_tempdir() { mktemp -d "${TMPDIR:-/tmp}/$TEMP_PREFIX$1.XXXXXX"; }

# ── the sandbox ──────────────────────────────────────────────────────────────────────────
# A harness that starts a real pi loads real extensions, and an extension may write OUTSIDE
# its own directory. helm-mail claims a mailbox under `~/.helm/mail` on session_start, so a
# gate run used to put a live, addressable mailbox in the operator's real root, beside the
# agents they actually talk to (#133). Measured on 0.83.0: BOTH real-pi harnesses claim one —
# rpc's is removed by the extension's own session_shutdown, pty's pi is killed and its mailbox
# is the one seen surviving. Self-healing is not the same as hermetic, and the window in which
# a throwaway mailbox is addressable is the whole hazard.
#
# The roots are pointed elsewhere ONCE, before any harness runs, rather than per harness. A
# harness added later then inherits the sandbox instead of having to remember it, which is
# exactly how pty came to be the odd one out.
#
# NOT by sandboxing HOME, which is the general form and was tried first: pi keeps its own
# tooling under `~/.pi/agent/bin`, so a fake HOME makes the first TUI run DOWNLOAD `fd` before
# it renders — measured, and it broke the banner assertion while it did. That trades a leaked
# mailbox for a network dependency in a gate whose whole point is being free and offline.
# Naming the roots is narrower and keeps the run hermetic where it matters. Add the next root
# to the list below.
SANDBOX=

# The operator's REAL roots, read from the inherited environment BEFORE it is overwritten —
# `HELM_MAIL_DIR` may already point somewhere that is not `~/.helm`, and that is the directory
# the guard has to protect.
#
# `HELM_DEFAULTS_SUITE` (#285) moves the mail root too, and deliberately does NOT get a second
# spelling here: `sandbox()` exports `HELM_MAIL_DIR`, which beats a suite in both writers, so
# nothing this gate runs can resolve a suite's mailroom in the first place.
REAL_MAIL_ROOT=${HELM_MAIL_DIR:-"${HOME:-/nonexistent}/.helm/mail"}

sandbox() {
	SANDBOX=$(make_tempdir sandbox) || return 1
	export HELM_MAIL_DIR="$SANDBOX/mail"
	# No pi extension writes the spool today; helm's tools do, and the next extension might.
	# One line now against a whole second incident of #133.
	export HELM_SPOOL_DIR="$SANDBOX/spool"
	# A pinned handle would name the mailbox something other than the harness's temp dir, and
	# the sweep below identifies the gate's own mailboxes by exactly that name. Unset it so a
	# developer who pinned a handle for their own session cannot blind the guard.
	unset HELM_MAIL_HANDLE
}

# The guard the sandbox is worth nothing without.
#
# It sweeps for the TEMP_PREFIX rather than diffing the directory, and that is deliberate: the
# operator's other agents claim and release mailboxes in this directory while the gate runs, so
# a before/after diff would fail on their work. Every mailbox the gate can create is named for
# the temp dir its harness ran in — helm-mail derives a handle from the cwd's basename — so the
# prefix names ours exactly and nobody else's.
assert_real_state_untouched() {
	[ -d "$REAL_MAIL_ROOT" ] || return 0
	local stray
	stray=$(ls "$REAL_MAIL_ROOT" 2>/dev/null | grep "^$TEMP_PREFIX" | tr '\n' ' ')
	[ -z "$stray" ] ||
		bad "sandbox: this run left mailboxes in the operator's real root $REAL_MAIL_ROOT: $stray"
}

# Every extension directory's name. The name is load-bearing: it is also the unit test's
# filename and, by convention, the command the extension registers.
extension_names() {
	local dir
	for dir in "$EXTENSIONS_DIR"/*/; do
		[ -d "$dir" ] || continue
		basename "$dir"
	done
}

# A temp workspace with the extensions copied in and pi's OWN type packages symlinked
# beside them. Nothing is vendored: the types are always whatever pi is installed right
# now, which is the entire point of the typecheck.
make_fixture() {
	local fixture=$1 dep
	# The same three packages both the typecheck and the unit harness symlink. Checked here
	# rather than in one caller, so a broken install is one clear line and not a raw
	# ERR_MODULE_NOT_FOUND stack trace from whichever tool happens to trip over it first.
	for dep in node_modules/typebox node_modules/@earendil-works/pi-tui node_modules/@types/node; do
		[ -d "$PI_PACKAGE_DIR/$dep" ] || { bad "installed pi is missing $dep"; return 1; }
	done
	mkdir -p "$fixture/node_modules/@earendil-works" "$fixture/node_modules/@types" ||
		{ bad "fixture: could not create $fixture"; return 1; }
	cp -R "$EXTENSIONS_DIR" "$fixture/extensions" ||
		{ bad "fixture: could not copy extensions into $fixture"; return 1; }
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
	if [ -x "$PROJECT_ROOT/pi/node_modules/.bin/tsc" ]; then printf %s "$PROJECT_ROOT/pi/node_modules/.bin/tsc"; return 0; fi
	if have_cmd tsc; then command -v tsc; return 0; fi
	return 1
}

# ── typecheck ────────────────────────────────────────────────────────────────────────────
# Why this matters more than it looks: measured on 0.83.0, subscribing to an event pi no
# longer has succeeds silently — pi.on() only pushes into a Map, so the handler simply never
# fires. Runtime cannot tell you. The typecheck is the ONLY place a removed event becomes
# visible, which is why extensions import the real ExtensionAPI instead of duck-typing it.
harness_typecheck() {
	have_cmd node || { skip "typecheck: node not found"; return 0; }
	have_cmd npm || { skip "typecheck: npm not found"; return 0; }
	have_pi_package || { skip "typecheck: no installed pi at $PI_PACKAGE_DIR"; return 0; }

	local tsc
	if ! tsc=$(find_tsc); then
		skip "typecheck: no tsc — run 'npm install' in pi/ to get one"
		return 0
	fi

	local fixture
	fixture=$(make_tempdir typecheck) || { bad "typecheck: mktemp failed"; return 0; }
	make_fixture "$fixture" || { rm -rf "$fixture"; return 0; }
	if "$tsc" -p "$fixture/tsconfig.json"; then
		say "ok - extensions typecheck strictly against pi $(pi_version)"
	else
		bad "typecheck failed against pi $(pi_version) — an API we use has changed"
	fi
	rm -rf "$fixture"
}

# ── unit ─────────────────────────────────────────────────────────────────────────────────
harness_unit() {
	have_cmd node || { skip "unit: node not found"; return 0; }
	have_pi_package || { skip "unit: no installed pi at $PI_PACKAGE_DIR (typebox comes from it)"; return 0; }

	local fixture before name
	before=$FAILURES
	fixture=$(make_tempdir unit) || { bad "unit: mktemp failed"; return 0; }
	make_fixture "$fixture" || { rm -rf "$fixture"; return 0; }
	for name in $(extension_names); do
		# A shipped extension with no unit harness is a DEFECT, not an absent toolchain:
		# skipping here would leave "the factory is total" — the one property measured as
		# catastrophic — unverified while the gate stayed green.
		[ -f "$TESTS_DIR/$name.mjs" ] || { bad "unit: $name has no tests/$name.mjs"; continue; }
		(cd "$fixture" && node "$TESTS_DIR/$name.mjs" "$fixture/extensions/$name/index.ts") ||
			bad "unit: $name failed its checks"
	done
	if [ "$FAILURES" -eq "$before" ]; then
		say "ok - every extension passes its unit harness, including a mutilated pi"
	fi
	rm -rf "$fixture"
}

# ── rpc ──────────────────────────────────────────────────────────────────────────────────
# `--no-extensions` suppresses BOTH auto-discovery and settings.json entries (measured), so
# with an explicit `-e` this run sees exactly one extension no matter what the machine has
# installed. Nothing here reaches a model: an extension command invoked as a `/`-prefixed
# prompt is handled locally.
rpc_one() {
	local name=$1 cwd=$2 ext="$EXTENSIONS_DIR/$1/index.ts"

	if ! (cd "$cwd" && printf '%s\n' '{"id":"1","type":"get_commands"}' |
		pi --mode rpc --no-session --no-extensions -e "$ext" >"$cwd/out.jsonl" 2>"$cwd/err"); then
		bad "rpc: $name — pi exited nonzero with the extension loaded"
		sed 's/^/    /' "$cwd/err" >&2
		return 1
	fi

	grep -q '"method":"notify"' "$cwd/out.jsonl" ||
		bad "rpc: $name — session_start produced no extension_ui_request notify frame"
	grep -q "$name v" "$cwd/out.jsonl" ||
		bad "rpc: $name — the notify frame did not carry the report"

	# The sandbox proved rather than assumed, and this is the only place it CAN be proved
	# deterministically: an extension that claims and then tidies up leaves nothing to find
	# afterwards, which is what made #133 hard to see. A report frame is untruncated JSON and
	# names the root the extension resolved, so a fallback to the operator's real directory
	# shows up here on the run that caused it, loudly, instead of as a mailbox someone finds
	# days later. A harness that forgets the sandbox fails on this line.
	grep -qF "$REAL_MAIL_ROOT" "$cwd/out.jsonl" &&
		bad "rpc: $name — reported the operator's real mail root $REAL_MAIL_ROOT; the sandbox is not in effect"

	# Whether the command is registered decides whether it is SAFE to invoke it, so this is
	# control flow and not just an assertion: bad() records a failure but does not return,
	# and a `/name` prompt that is not a registered command is forwarded to the model.
	if node -e '
		const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
		const found = lines.some((line) => {
			try {
				const frame = JSON.parse(line);
				return frame.command === "get_commands" && frame.data.commands.some((c) => c.name === process.argv[2]);
			} catch { return false; }
		});
		process.exit(found ? 0 : 1);
	' "$cwd/out.jsonl" "$name"; then
		if (cd "$cwd" && printf '{"id":"1","type":"prompt","message":"/%s"}\n' "$name" |
			pi --mode rpc --no-session --no-extensions -e "$ext" >"$cwd/cmd.jsonl" 2>/dev/null); then
			grep -q '"type":"agent_start"' "$cwd/cmd.jsonl" &&
				bad "rpc: $name — invoking /$name started an agent turn; that would spend credits"
			[ "$(grep -c '"method":"notify"' "$cwd/cmd.jsonl")" -ge 2 ] ||
				bad "rpc: $name — /$name did not report"
		else
			bad "rpc: $name — invoking /$name exited nonzero"
		fi
	else
		bad "rpc: $name — /$name is not in get_commands; not invoking it, that would reach the model"
	fi
}

harness_rpc() {
	have_cmd pi || { skip "rpc: pi not on PATH"; return 0; }
	have_cmd node || { skip "rpc: node not found"; return 0; }

	local cwd before name
	before=$FAILURES
	cwd=$(make_tempdir rpc) || { bad "rpc: mktemp failed"; return 0; }

	for name in $(extension_names); do
		rpc_one "$name" "$cwd" || continue
	done

	# The kill switch has to actually kill. helm-probe's is the reference implementation;
	# an extension without one simply has nothing to assert here.
	if (cd "$cwd" && printf '%s\n' '{"id":"1","type":"get_commands"}' |
		HELM_PROBE_OFF=1 pi --mode rpc --no-session --no-extensions \
			-e "$EXTENSIONS_DIR/helm-probe/index.ts" >"$cwd/off.jsonl" 2>/dev/null); then
		grep -q '"method":"notify"' "$cwd/off.jsonl" &&
			bad "rpc: HELM_PROBE_OFF did not switch the extension off"
	else
		bad "rpc: pi exited nonzero with the extension switched off"
	fi

	if [ "$FAILURES" -eq "$before" ]; then
		say "ok - every extension loads under a real pi --mode rpc, reports, and switches off"
	fi
	rm -rf "$cwd"
}

# ── pty ──────────────────────────────────────────────────────────────────────────────────
# The one thing rpc cannot show: that a real interactive pi reaches a normal prompt with
# our extension loaded. `script` gives it a pty; stdin is /dev/null so pi renders and exits.
pty_one() {
	local name=$1 cwd=$2 ext="$EXTENSIONS_DIR/$1/index.ts" raw="$2/$1.raw"
	# A token unique to this run, planted in the child's argv via `env`. The cleanup below
	# has to reach a grandchild (script's own child pi), and a bare `pkill -f <extension
	# path>` would also kill a second, concurrent run of this suite — parallel CI, or two
	# terminals. Matching the token keeps the kill inside this run.
	local token="helm-pty-$$-$name"

	(
		cd "$cwd" || exit 1
		if script --version 2>/dev/null | grep -qi util-linux; then
			script -q -c "env HELM_PTY_RUN='$token' pi --no-session --no-extensions -e '$ext'" /dev/null
		else
			script -q /dev/null env "HELM_PTY_RUN=$token" pi --no-session --no-extensions -e "$ext"
		fi
	) >"$raw" 2>&1 </dev/null &
	local runner=$!

	# Bounded wait for the report to appear, then stop whatever is left. No `timeout`
	# dependency: helm's own tools take the same line, and a poll says what it waited for.
	local i=0
	while [ "$i" -lt 200 ]; do
		grep -q "$name v" "$raw" 2>/dev/null && break
		kill -0 "$runner" 2>/dev/null || break
		sleep 0.1
		i=$((i + 1))
	done
	kill "$runner" 2>/dev/null
	wait "$runner" 2>/dev/null
	pkill -f "$token" 2>/dev/null

	local screen
	screen=$(LC_ALL=C sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\x1b\\][^\x07]*\x07//g' "$raw" | tr -d '\r')
	if ! printf '%s' "$screen" | grep -q 'pi v'; then
		bad "pty: $name — pi never rendered its banner; it did not reach a prompt"
	elif ! printf '%s' "$screen" | grep -q "$name v"; then
		bad "pty: $name — pi reached a prompt but the extension never reported"
	fi
}

harness_pty() {
	have_cmd pi || { skip "pty: pi not on PATH"; return 0; }
	have_cmd script || { skip "pty: script not found"; return 0; }

	local cwd before name
	before=$FAILURES
	cwd=$(make_tempdir pty) || { bad "pty: mktemp failed"; return 0; }

	for name in $(extension_names); do
		pty_one "$name" "$cwd"
	done

	if [ "$FAILURES" -eq "$before" ]; then
		say "ok - a real TUI reaches a normal prompt with every extension loaded"
	fi
	rm -rf "$cwd"
}

# No sandbox, no run. Refusing costs a developer one confusing minute; carrying on would put a
# throwaway mailbox in a directory seven live agents address each other through, which is the
# defect rather than an inconvenience. This is before the dispatch so it covers every harness,
# including `typecheck` and `unit`, which do not need it today.
if ! sandbox; then
	bad "sandbox: could not make a temp directory under ${TMPDIR:-/tmp}; refusing to run against the operator's real ~/.helm"
	say "# $FAILURES check(s) failed"
	exit 1
fi

case "${1:-all}" in
	typecheck) harness_typecheck ;;
	unit)      harness_unit ;;
	rpc)       harness_rpc ;;
	pty)       harness_pty ;;
	all)       harness_typecheck; harness_unit; harness_rpc; harness_pty ;;
	*)         rm -rf "$SANDBOX"; say "usage: bash <this-script> [typecheck|unit|rpc|pty|all]"; exit 2 ;;
esac

assert_real_state_untouched
rm -rf "$SANDBOX"

if [ "$FAILURES" -ne 0 ]; then
	say "# $FAILURES check(s) failed"
	exit 1
fi
say "# pi extensions ok"
