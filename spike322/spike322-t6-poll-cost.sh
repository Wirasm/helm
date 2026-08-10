#!/bin/bash
# spike322 T6 — assumption 4: what ONE poll costs, as a number.
# A poll is a turn. Measure a real one, three times, with the runtime's own accounting.
set -u
SPIKE=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322
export HELM_DEFAULTS_SUITE=spike322
export SPIKE322_LOG=/tmp/spike322-cost.log
: > "$SPIKE322_LOG"
chmod +x "$SPIKE/bench-mail-logged"
W=$(mktemp -d /tmp/spike322-cost.XXXXXX); cd "$W" || exit 1

P="Run exactly this one command and report its output verbatim, then stop: $SPIKE/bench-mail-logged check"

echo "=== claude: three no-mail polls, with Claude Code's own cost accounting ==="
for i in 1 2 3; do
  a=$(python3 -c 'import time;print(int(time.time()*1000))')
  timeout 300 claude -p --dangerously-skip-permissions --output-format json "$P" 2>/dev/null > "out$i.json"
  b=$(python3 -c 'import time;print(int(time.time()*1000))')
  python3 - "$i" "$((b-a))" <<'PY'
import json, sys
i, wall = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f"out{i}.json"))
except Exception as e:
    print(f"run {i}: could not parse ({e})"); raise SystemExit
u = d.get("usage") or {}
print(f"run {i}: wall={wall}ms  cost_usd={d.get('total_cost_usd')}  "
      f"duration_api_ms={d.get('duration_api_ms')}  turns={d.get('num_turns')}")
print(f"        input={u.get('input_tokens')} output={u.get('output_tokens')} "
      f"cache_read={u.get('cache_read_input_tokens')} cache_creation={u.get('cache_creation_input_tokens')}")
PY
done

echo
echo "=== invocations actually logged ==="
cat "$SPIKE322_LOG"
echo "count=$(wc -l < "$SPIKE322_LOG")"
echo "W=$W"
