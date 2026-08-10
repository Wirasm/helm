#!/bin/bash
# spike322 T4 — assumption 3, the decisive test.
#
# AGENTS.md: "there is no shared module because pi loads a .ts extension and a hook is a
# standalone script". Test it. One .mjs module; three consumers: the CLI, a hook, a pi
# extension loaded THROUGH A SYMLINK the way pi extensions really are installed.
set -u
SPIKE=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322
export HELM_DEFAULTS_SUITE=spike322
ROOT="$HOME/.helm/mail-spike322"
WORK=$(mktemp -d /tmp/spike322-shared.XXXXXX)
cd "$WORK" || exit 1
echo "work=$WORK"

echo "=== A. the hook, importing the shared module (claim) ==="
echo '{"session_id":"spike322-hook-session-aaaa1111","cwd":"'"$WORK"'"}' | timeout 60 node "$SPIKE/hook.mjs" claim
echo "exit=$?"
ls -1 "$ROOT"

echo
echo "=== B. the pi extension, loaded through a SYMLINK, importing the same module ==="
EXTDIR=$(mktemp -d /tmp/spike322-ext.XXXXXX)
ln -s "$SPIKE/pi-ext" "$EXTDIR/spike322"
echo "symlink: $(ls -l "$EXTDIR/spike322" | sed 's/.*-> //')"
echo "--- node's own resolution through the symlink (no pi involved) ---"
timeout 60 node --input-type=module -e "
const m = await import('$EXTDIR/spike322/index.ts').catch(e => ({ err: e }));
console.log(m.err ? 'IMPORT FAILED: ' + m.err.message : 'ts import OK, default=' + typeof m.default);
" 2>&1 | tail -5
echo "--- a plain .mjs sibling import through the same symlink ---"
timeout 60 node --input-type=module -e "
const c = await import('$EXTDIR/spike322/../bench-mail-core.mjs').catch(e => ({ err: e }));
console.log(c.err ? 'MJS IMPORT FAILED: ' + c.err.message : 'mjs import OK, mailRoot=' + c.mailRoot());
" 2>&1 | tail -5

echo
echo "=== C. a REAL pi loading it (headless, no model call: --no-tools and an empty prompt) ==="
timeout 180 pi -p -ne -e "$EXTDIR/spike322/index.ts" --no-session "say only: ok" 2>&1 | grep -iE "spike322|error|cannot|fail" | head -20
echo "pi exit=$?"

echo
echo "=== D. what pi 0.83.0 actually is: does it load .ts natively? ==="
node --version
node -e "console.log('type stripping:', process.features.typescript)"

echo "WORKDIR=$WORK EXTDIR=$EXTDIR"
