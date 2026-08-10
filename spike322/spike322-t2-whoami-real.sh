#!/bin/bash
# spike322 T2a — does the ancestry join find a REAL, hook-claimed mailbox?
# READ ONLY: `whoami` and `list` never write. Nothing here touches ~/.helm/mail contents.
set -u
CLI=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail
cd /tmp || exit 1
unset HELM_DEFAULTS_SUITE
echo "=== whoami against the operator's real root (read-only) ==="
"$CLI" whoami; echo "exit=$?"
echo
echo "=== what my own session's owner.json says (read-only) ==="
H=$("$CLI" whoami | awk '/^handle:/{print $2}')
echo "handle=$H"
cat "$HOME/.helm/mail/$H/owner.json" 2>&1
