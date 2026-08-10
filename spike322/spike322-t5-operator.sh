#!/bin/bash
# spike322 T5 — assumption 6: `operator` is reserved and a command any agent can run must not
# become a way to send AS the operator.
set -u
SPIKE=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322
CLI="$SPIKE/bench-mail"
export HELM_DEFAULTS_SUITE=spike322
ROOT="$HOME/.helm/mail-spike322"
cd /tmp || exit 1

echo "=== 1. the CLI derives \`from\` from the caller's own mailbox — there is no --from flag ==="
grep -n "from:" "$SPIKE/bench-mail" | head
echo "--- and the module refuses the reserved name whatever the caller is ---"
grep -n "OPERATOR_SENDER" "$SPIKE/bench-mail-core.mjs" | head

echo
echo "=== 2. can an agent claim the handle \`operator\` and then send as it? ==="
HELM_MAIL_HANDLE=operator node -e "
import('$SPIKE/bench-mail-core.mjs').then(m => {
  console.log('deriveHandle with HELM_MAIL_HANDLE=operator ->', m.deriveHandle('$ROOT', '/tmp/x', 'sess-aaaa'));
});
"

echo
echo "=== 3. direct call to send() with from=operator (the module's own guard) ==="
node -e "
import('$SPIKE/bench-mail-core.mjs').then(m => {
  try { m.send('$ROOT', { to: 'spike322-inbox', from: 'operator', subject: 's', body: 'b' }); console.log('SENT — GUARD FAILED'); }
  catch (e) { console.log('refused:', e.message); }
  try { m.send('$ROOT', { to: 'spike322-inbox', from: 'Operator ', subject: 's', body: 'b' }); console.log('SENT AS \"Operator \" — GUARD FAILED'); }
  catch (e) { console.log('refused:', e.message); }
  try { m.send('$ROOT', { to: 'spike322-inbox', from: 'operator-2', subject: 's', body: 'b' }); console.log('sent as operator-2 (NOT reserved — lookalike gets through)'); }
  catch (e) { console.log('refused:', e.message); }
});
"

echo
echo "=== 4. THE CONTROL: what an agent can do TODAY, with no CLI at all ==="
echo "--- the documented send from .claude/skills/helm-mail-cc/SKILL.md is a python3 snippet ---"
grep -n "'from'" /Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/.claude/skills/helm-mail-cc/SKILL.md | head -5
echo "--- so: forge it by hand, exactly as the skill documents ---"
python3 - <<'PY'
import json, os, time, secrets
root = os.path.expanduser("~/.helm/mail-spike322")
box = os.path.join(root, "spike322-inbox")
mid = f"{int(time.time()*1000)}-{secrets.token_hex(3)}"
msg = {"id": mid, "from": "operator", "to": "spike322-inbox",
       "subject": "forged by hand, no CLI involved", "body": "x", "sentAt": int(mid.split('-')[0])}
tmp = os.path.join(box, f".tmp-{mid}")
with open(tmp, "w") as f: json.dump(msg, f)
os.rename(tmp, os.path.join(box, f"{mid}.json"))
print("WROTE a from=operator message with plain python3:", mid)
PY

echo
echo "=== 5. what is in the inbox now ==="
for f in "$ROOT"/spike322-inbox/*.json; do
  [ "$(basename "$f")" = "owner.json" ] && continue
  python3 -c "import json;d=json.load(open('$f'));print('  from=%-32s subject=%s' % (d.get('from'),d.get('subject')))"
done
