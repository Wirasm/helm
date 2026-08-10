#!/bin/bash
# spike322 T8 — assumption 5: if the hook and the extension become sensors that CALL the one
# implementation, what does the call cost on the operator's critical path?
#
# `UserPromptSubmit` fires on every prompt the operator types. Three shapes, measured:
#   (a) today — a node hook holding its own copy of the rules
#   (b) sensor-by-import — a node hook importing the shared .mjs
#   (c) sensor-by-exec — a node hook spawning `bench mail`
#   (d) sensor-by-exec into a SWIFT `bench mail`, the shape `tools/*.swift` would give
set -u
REPO=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d
SPIKE=$REPO/spike322
export HELM_DEFAULTS_SUITE=spike322
cd /tmp || exit 1
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
PAYLOAD='{"session_id":"spike322-t8-session-bbbb2222","cwd":"/tmp"}'

echo "=== (a) today: hooks/helm-mail.mjs deliver (its own copy of the rules) ==="
for i in 1 2 3 4 5; do
  a=$(ms); echo "$PAYLOAD" | node "$REPO/hooks/helm-mail.mjs" deliver >/dev/null 2>&1; b=$(ms); echo "  $((b-a)) ms"
done

echo "=== (b) sensor by IMPORT: spike322/hook.mjs deliver (shared module, no copy) ==="
for i in 1 2 3 4 5; do
  a=$(ms); echo "$PAYLOAD" | node "$SPIKE/hook.mjs" deliver >/dev/null 2>&1; b=$(ms); echo "  $((b-a)) ms"
done

echo "=== (c) sensor by EXEC: a node hook spawning the node CLI ==="
cat > /tmp/spike322-exec-hook.mjs <<'EOF'
import { execFileSync } from "node:child_process";
const chunks = []; for await (const c of process.stdin) chunks.push(c);
try {
  const out = execFileSync("/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322/bench-mail",
    ["check"], { encoding: "utf8" });
  if (!/^no mail/.test(out)) process.stdout.write(out);
} catch { /* exit 0 on any uncertainty, per the hook contract */ }
process.exit(0);
EOF
for i in 1 2 3 4 5; do
  a=$(ms); echo "$PAYLOAD" | node /tmp/spike322-exec-hook.mjs >/dev/null 2>&1; b=$(ms); echo "  $((b-a)) ms"
done

echo "=== (d) sensor by EXEC into a SWIFT bench mail (proxy: any tools/*.swift script) ==="
for i in 1 2 3; do
  a=$(ms); swift "$REPO/tools/helm-command.swift" --list >/dev/null 2>&1; b=$(ms); echo "  $((b-a)) ms (swift script floor)"
done
