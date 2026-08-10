#!/bin/bash
# spike322 T1 — assumption 2: no build, no cwd inside the repo, no resolved dependencies.
set -u
CLI=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail
chmod +x "$CLI"
export HELM_DEFAULTS_SUITE=spike322

echo "=== A. from a cwd that is not the repo and not even under it ==="
cd / || exit 1
echo "cwd=$(pwd)"
"$CLI" whoami; echo "exit=$?"

echo
echo "=== B. from \$HOME ==="
cd "$HOME" || exit 1
echo "cwd=$(pwd)"
"$CLI" list; echo "exit=$?"

echo
echo "=== C. is there a .build/ or resolved dependency anywhere it needs? ==="
ls -d /Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/.build 2>&1
ls -d /Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/vendor 2>&1
echo "-- does the CLI import anything outside its own directory? --"
grep -n '^import' /Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail

echo
echo "=== D. copied OUT of the repo entirely, run from a bare temp dir ==="
T=$(mktemp -d)
cp /Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail* "$T"/
cd "$T" || exit 1
echo "cwd=$(pwd)"
"$T/bench-mail" whoami; echo "exit=$?"
rm -rf "$T"

echo
echo "=== E. invocation cost, 5 runs ==="
cd /tmp || exit 1
for i in 1 2 3 4 5; do
  a=$(python3 -c 'import time;print(int(time.time()*1000))')
  "$CLI" list >/dev/null 2>&1
  b=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "run $i: $((b-a)) ms"
done
