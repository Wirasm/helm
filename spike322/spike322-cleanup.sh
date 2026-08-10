#!/bin/bash
# spike322 — clean my own litter out of the operator's shared mailroom.
# ONLY directories whose names this spike created. Anything else is left alone.
# Checked first: they must be dead, and hold no mail anyone sent.
set -u
ROOT="$HOME/.helm/mail"
echo "=== candidates (spike322-*) ==="
for d in "$ROOT"/spike322-*/; do
  [ -d "$d" ] || continue
  h=$(basename "$d")
  pid=$(python3 -c "import json;print(json.load(open('$d/owner.json')).get('pid'))" 2>/dev/null)
  alive=$(kill -0 "$pid" 2>/dev/null && echo LIVE || echo dead)
  q=$(find "$d" -maxdepth 1 -name '*.json' ! -name owner.json -type f | wc -l | tr -d ' ')
  r=$(find "$d/read" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  $h pid=$pid $alive queued=$q read=$r"
done
echo
echo "=== ACTION: remove only the dead ones with zero queued and zero read ==="
for d in "$ROOT"/spike322-*/; do
  [ -d "$d" ] || continue
  h=$(basename "$d")
  pid=$(python3 -c "import json;print(json.load(open('$d/owner.json')).get('pid'))" 2>/dev/null)
  if kill -0 "$pid" 2>/dev/null; then echo "  SKIP $h (pid $pid still alive)"; continue; fi
  q=$(find "$d" -maxdepth 1 -name '*.json' ! -name owner.json -type f | wc -l | tr -d ' ')
  r=$(find "$d/read" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$q" != "0" ] || [ "$r" != "0" ]; then echo "  SKIP $h (holds mail: queued=$q read=$r)"; continue; fi
  rm -rf "$d" && echo "  removed $h"
done
echo
echo "=== after ==="
ls "$ROOT" | wc -l
ls -d "$ROOT"/spike322-* 2>&1 | head
