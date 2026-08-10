#!/bin/bash
# spike322 T9 — the negative control FAILED. Why did a `claude -p` launched with
# HELM_DEFAULTS_SUITE=spike322 claim a mailbox in the operator's SHARED ~/.helm/mail?
set -u
export HELM_DEFAULTS_SUITE=spike322
W=$(mktemp -d /tmp/spike322-leak.XXXXXX); cd "$W" || exit 1
echo "work=$W"

echo "=== 1. does the session itself see the variable? ==="
timeout 200 claude -p --dangerously-skip-permissions \
  'Run exactly: env | grep -E "HELM_DEFAULTS_SUITE|HELM_MAIL" ; echo "---" ; echo $HELM_DEFAULTS_SUITE — and paste the raw output only.' 2>&1 | tail -12

echo
echo "=== 2. which root did the hook claim in, for THIS cwd? ==="
SLUG=$(basename "$W" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')
echo "slug=$SLUG"
echo "-- shared root --"; ls -d "$HOME/.helm/mail/$SLUG"* 2>&1
echo "-- suite root  --"; ls -d "$HOME/.helm/mail-spike322/$SLUG"* 2>&1

echo
echo "=== 3. what does the operator's settings.json actually wire? ==="
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
for event, entries in (d.get("hooks") or {}).items():
    for e in entries:
        for h in e.get("hooks", []):
            if "helm" in json.dumps(h):
                print(f"{event}: {h.get('command')}")
PY

echo
echo "=== 4. which helm-mail.mjs is that, and does it have the #285 suite rule? ==="
grep -n "SUITE_ENV\|mail-\${suite}" /Users/rasmus/Projects/mine/sild/helm/hooks/helm-mail.mjs | head -5
