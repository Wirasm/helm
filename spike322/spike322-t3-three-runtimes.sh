#!/bin/bash
# spike322 T3 — assumption 1: send and read from codex, pi and Claude Code, one mailbox,
# no per-runtime integration.
#
# Everything happens under HELM_DEFAULTS_SUITE=spike322, so the root is ~/.helm/mail-spike322
# and the operator's ~/.helm/mail is never touched. Every child is `timeout`-bounded.
set -u
CLI=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail
export HELM_DEFAULTS_SUITE=spike322
ROOT="$HOME/.helm/mail-spike322"
WORK=$(mktemp -d /tmp/spike322-work.XXXXXX)
cd "$WORK" || exit 1
echo "work=$WORK  root=$ROOT"

# The shared target every runtime writes into. Claimed by hand so it is live and unretired.
mkdir -p "$ROOT/spike322-inbox/read"
cat > "$ROOT/spike322-inbox/owner.json" <<EOF
{"handle":"spike322-inbox","runtime":"spike","pid":$$,"sessionId":"spike322-inbox","cwd":"$WORK","claimedAt":$(python3 -c 'import time;print(int(time.time()*1000))')}
EOF
echo "--- inbox claimed ---"

PROMPT='Run these three shell commands in order and paste their exact output, nothing else:
1) '"$CLI"' claim
2) '"$CLI"' whoami
3) '"$CLI"' send spike322-inbox "hello from RUNTIME"
Do not read or edit any files. Do not do anything else.'

echo
echo "=================== CLAUDE CODE ==================="
timeout 300 claude -p --dangerously-skip-permissions "${PROMPT/RUNTIME/claude}" 2>&1 | tail -20
echo "claude exit=$?"

echo
echo "=================== CODEX ==================="
timeout 300 codex exec --dangerously-bypass-approvals-and-sandbox "${PROMPT/RUNTIME/codex}" 2>&1 | tail -25
echo "codex exit=$?"

echo
echo "=================== PI ==================="
timeout 300 pi -p --approve "${PROMPT/RUNTIME/pi}" 2>&1 | tail -25
echo "pi exit=$?"

echo
echo "=================== RESULT: what landed in the one mailbox ==================="
ls -1 "$ROOT"
echo "--- inbox contents ---"
for f in "$ROOT"/spike322-inbox/*.json; do
  [ "$(basename "$f")" = "owner.json" ] && continue
  echo "### $f"
  python3 -c "import json,sys;d=json.load(open('$f'));print(' from=%s to=%s subject=%s' % (d.get('from'),d.get('to'),d.get('subject')))"
done
echo "--- owner.json of every box that got claimed ---"
for d in "$ROOT"/*/; do
  echo "### $d"
  cat "$d/owner.json" 2>/dev/null | tr -d '\n' | head -c 300; echo
done
echo "WORKDIR=$WORK"
