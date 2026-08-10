#!/bin/bash
# spike322 T7d — did the cron WAKE an idle session, and do the other two runtimes have one?
set -u
F=$(ls -t "$HOME"/.claude/projects/-private-tmp-spike322-idle-naive/*.jsonl | head -1)
echo "=== every message after 12:44:30, with who spoke ==="
python3 - "$F" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try: d = json.loads(line)
    except Exception: continue
    ts = d.get("timestamp") or ""
    if ts < "2026-08-10T12:44:30": continue
    m = d.get("message") or {}
    role = d.get("type")
    txt = ""
    c = m.get("content")
    if isinstance(c, str): txt = c
    elif isinstance(c, list):
        for x in c:
            if isinstance(x, dict):
                if x.get("type") == "text": txt += x.get("text", "")
                elif x.get("type") == "tool_use": txt += f"[tool_use {x.get('name')}]"
                elif x.get("type") == "tool_result": txt += "[tool_result]"
    print(f"{ts} {role:10s} {txt[:150].replace(chr(10),' ')}")
PY

echo
echo "=== does codex ship a scheduler? ==="
ls "$HOME/.codex/automations" 2>&1 | head
codex --help 2>&1 | grep -iE "cron|schedul|automation|timer" | head
echo "codex-grep-exit=$?"

echo
echo "=== does pi ship a scheduler? ==="
pi --help 2>&1 | grep -iE "cron|schedul|timer|interval" | head
echo "pi-grep-exit=$?"

echo
echo "=== does Claude Code's cron survive the session? (its own words) ==="
echo "see T7c: 'Session-only (not written to disk, dies when Claude exits)'"
