#!/bin/bash
# spike322 — invocation cost of the three candidate implementation languages, from a cwd
# OUTSIDE the repo, with no build. Each measured 5x; we report each run's wall time.
set -u
REPO=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d
OUT=/private/tmp/claude-501/-Users-rasmus-Projects-mine-sild-helm/d08c9a03-c1e1-4bab-be25-2354cbf784a1/scratchpad
cd /tmp || exit 1
echo "cwd=$(pwd)"

ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

echo "== swift single-file script (tools/helm-command.swift --list) =="
for i in 1 2 3 4 5; do
  a=$(ms); timeout 120 swift "$REPO/tools/helm-command.swift" --list >/dev/null 2>&1; rc=$?; b=$(ms)
  echo "run $i: $((b-a)) ms (exit $rc)"
done

echo "== node script (hooks/helm-mail.mjs with no verb, stdin closed) =="
for i in 1 2 3 4 5; do
  a=$(ms); echo '{}' | timeout 120 node "$REPO/hooks/helm-mail.mjs" >/dev/null 2>&1; rc=$?; b=$(ms)
  echo "run $i: $((b-a)) ms (exit $rc)"
done

echo "== python3 (the language both SKILL.md snippets already use) =="
for i in 1 2 3 4 5; do
  a=$(ms); timeout 120 python3 -c 'import json,os,sys' >/dev/null 2>&1; rc=$?; b=$(ms)
  echo "run $i: $((b-a)) ms (exit $rc)"
done
