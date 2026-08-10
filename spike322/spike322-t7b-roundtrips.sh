#!/bin/bash
# spike322 T7b — is each poll a MODEL ROUND-TRIP, or one blocking shell loop?
# Read the polling session's own transcript and count.
set -u
D=$(ls -dt "$HOME"/.claude/projects/*spike322-idle-naive* 2>/dev/null | head -1)
echo "project dir: $D"
F=$(ls -t "$D"/*.jsonl 2>/dev/null | head -1)
echo "transcript:  $F"
python3 - "$F" <<'PY'
import json, sys
f = sys.argv[1]
assist = 0
tools = []
rows = []
for line in open(f):
    try: d = json.loads(line)
    except Exception: continue
    m = d.get("message") or {}
    if d.get("type") == "assistant":
        assist += 1
        u = m.get("usage") or {}
        rows.append((d.get("timestamp"), u.get("input_tokens"), u.get("cache_read_input_tokens"),
                     u.get("cache_creation_input_tokens"), u.get("output_tokens")))
        for c in (m.get("content") or []):
            if isinstance(c, dict) and c.get("type") == "tool_use":
                cmd = (c.get("input") or {}).get("command", "")
                tools.append((c.get("name"), cmd[:110]))
print(f"assistant messages (model round-trips): {assist}")
print(f"tool_use blocks: {len(tools)}")
for n, c in tools:
    print(f"   {n}: {c}")
print("per-round-trip usage:")
tot_in = tot_cr = tot_cc = tot_out = 0
for ts, i, cr, cc, o in rows:
    print(f"   {ts} input={i} cache_read={cr} cache_creation={cc} output={o}")
    tot_in += i or 0; tot_cr += cr or 0; tot_cc += cc or 0; tot_out += o or 0
print(f"TOTAL input={tot_in} cache_read={tot_cr} cache_creation={tot_cc} output={tot_out}")
PY
