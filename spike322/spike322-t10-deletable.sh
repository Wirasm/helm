#!/bin/bash
# spike322 T10 — assumption 3: PROVE WHAT CAN BE DELETED, not what can be added.
# Count the rule-bearing regions of each copy, by their own section markers.
set -u
R=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d

echo "=== hooks/helm-mail.mjs — its own section markers ==="
grep -n "^// ──" "$R/hooks/helm-mail.mjs"
echo "total: $(wc -l < "$R/hooks/helm-mail.mjs")"

echo
echo "=== pi/extensions/helm-mail/index.ts — its own section markers ==="
grep -n "^// ──" "$R/pi/extensions/helm-mail/index.ts"
echo "total: $(wc -l < "$R/pi/extensions/helm-mail/index.ts")"

echo
echo "=== the two SKILL.md files: how much is the \$ROOT preamble + the send/list snippets ==="
for f in helm-mail-cc helm-mail-pi; do
  echo "--- $f/SKILL.md ($(wc -l < "$R/.claude/skills/$f/SKILL.md") lines) ---"
  grep -c 'ROOT=' "$R/.claude/skills/$f/SKILL.md" | sed 's/^/  ROOT= occurrences: /'
  grep -n 'case "\$HELM_DEFAULTS_SUITE"' "$R/.claude/skills/$f/SKILL.md" | wc -l | sed 's/^/  suite-guard preambles: /'
  awk '/^```/{n++} END{print "  fenced blocks: " int(n/2)}' "$R/.claude/skills/$f/SKILL.md"
done

echo
echo "=== gates that exist because of the duplication ==="
wc -l "$R/hooks/mailbox-conformance.mjs" "$R/hooks/test.sh" "$R/.claude/skills/helm-mail-cc/test.sh"

echo
echo "=== the Swift side, which a CLI does NOT collapse ==="
wc -l "$R/Sources/HelmWire/Spool/MailboxDirectory.swift" "$R/Sources/Helm/Mail/MailMessage.swift"
echo "--- who in Swift READS the mailbox synchronously (so cannot shell out per tick) ---"
grep -rn "MailboxDirectory.owners\|AddressBook(" "$R/Sources/Helm" --include=*.swift | head -20
