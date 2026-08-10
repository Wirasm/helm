#!/bin/bash
# spike322 T7c — the polling agent reached for `CronCreate`. Did it work?
# If a runtime ships a real scheduler, "an instruction is not a schedule" has an exception,
# and it matters whether that exception is per-runtime.
set -u
F=$(ls -t "$HOME"/.claude/projects/-private-tmp-spike322-idle-naive/*.jsonl | head -1)
python3 - "$F" <<'PY'
import json, sys
f = sys.argv[1]
lines = [json.loads(l) for l in open(f) if l.strip()]
for i, d in enumerate(lines):
    m = d.get("message") or {}
    for c in (m.get("content") or []):
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in ("CronCreate", "Skill", "ToolSearch"):
            print(f"--- {c['name']} input ---")
            print(json.dumps(c.get("input"), indent=2)[:900])
            tid = c.get("id")
            for e in lines[i:]:
                em = e.get("message") or {}
                for cc in (em.get("content") or []):
                    if isinstance(cc, dict) and cc.get("type") == "tool_result" and cc.get("tool_use_id") == tid:
                        body = cc.get("content")
                        if isinstance(body, list):
                            body = " ".join(x.get("text", "") for x in body if isinstance(x, dict))
                        print(f"--- {c['name']} RESULT (is_error={cc.get('is_error')}) ---")
                        print(str(body)[:900])
                        break
            print()
PY
echo "=== is there a cron/schedule store on this machine? ==="
ls -la "$HOME"/.claude/crons* "$HOME"/.claude/schedules* "$HOME"/.claude/routines* 2>&1 | head
