#!/bin/bash
# spike322 T11 — the correction. My "codex cannot be scheduled" was INFERENCE: I grepped
# `codex --help` and found ~/.codex/automations empty. I never asked a codex agent.
# Proving an absence by reading help text is the error #320's spike made in the other
# direction. So: ask them. Same instruction Claude Code got, same log, same counting.
#
# Every child is timeout-bounded twice (outer `timeout`, inner deadline).
set -u
SPIKE=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322
export HELM_DEFAULTS_SUITE=spike322
CLI="$SPIKE/bench-mail-logged"
W=$(mktemp -d /tmp/spike322-poll.XXXXXX); cd "$W" || exit 1

P="Run this command now: $CLI check
Then keep running that same command every 60 seconds for the next 5 minutes, so you stay
reachable. Nobody will prompt you again. Use whatever mechanism you have — a scheduler, a
timer, a background job, a blocking loop, anything. If you have no way to make it recur, say
so explicitly and stop."

echo "############ CODEX ############"
export SPIKE322_LOG=/tmp/spike322-poll-codex.log; : > "$SPIKE322_LOG"
START=$(date -u +%s)
timeout 420 codex exec --dangerously-bypass-approvals-and-sandbox "$P" 2>&1 | tail -30
echo "--- codex process exited at +$(( $(date -u +%s) - START ))s ---"
echo "invocations DURING the codex run: $(wc -l < "$SPIKE322_LOG" | tr -d ' ')"
cat "$SPIKE322_LOG"
echo "--- now watch 180s with codex GONE (nothing may fire) ---"
sleep 180
echo "invocations after codex exited: $(wc -l < "$SPIKE322_LOG" | tr -d ' ')"

echo
echo "############ PI ############"
export SPIKE322_LOG=/tmp/spike322-poll-pi.log; : > "$SPIKE322_LOG"
START=$(date -u +%s)
timeout 420 pi -p --approve "$P" 2>&1 | tail -30
echo "--- pi process exited at +$(( $(date -u +%s) - START ))s ---"
echo "invocations DURING the pi run: $(wc -l < "$SPIKE322_LOG" | tr -d ' ')"
cat "$SPIKE322_LOG"
echo "--- now watch 180s with pi GONE ---"
sleep 180
echo "invocations after pi exited: $(wc -l < "$SPIKE322_LOG" | tr -d ' ')"

echo
echo "W=$W"
