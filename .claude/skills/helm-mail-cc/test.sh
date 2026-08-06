#!/usr/bin/env bash
# Gate for the shell snippets this skill DOCUMENTS. Needs bash, zsh and python3 — nothing
# else, and deliberately not part of the Swift gate, for the reason helm-canvas's gate is
# not: `swift test` cannot run a shell script and should not learn how.
#
#   bash .claude/skills/helm-mail-cc/test.sh
#
# Why this file exists at all: nothing checked a skill file, and #237 is what that cost. The
# documented watch was `for f in "$BOX"/*.json`, which under zsh is a FATAL error on an empty
# mailbox rather than an empty list — so the watch did not iterate zero times, it died, and
# the agent went dark with no notification and no way to notice from inside a turn it was not
# having. It read as correct because the guard beside it (`case "$f" in *owner.json|*'*.json')`)
# is bash's behaviour of leaving an unmatched glob in place as literal text. Correct in bash,
# never reached in zsh. Claude Code's own Bash tool runs /bin/zsh.
#
# So the checks below EXTRACT the snippet from SKILL.md and run it, rather than restating it.
# A test that retypes the snippet is a second copy of it, and a second copy drifts — it would
# have gone on passing while the doc said something else entirely, which is the whole failure
# being fixed.
#
# What it CANNOT prove: that an agent reading this skill arms the watch at all, or that the
# Monitor tool turns its stdout into a notification. That is the runtime's contract and needs
# real agents run at each other.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cc="$here/SKILL.md"
pi="$here/../helm-mail-pi/SKILL.md"
tmp=$(mktemp -d)

watch_pid=""
cleanup() {
    # `wait` after the kill, so bash reaps the job here instead of printing "Terminated: 15"
    # over the summary line — the last thing anyone reads.
    if [ -n "$watch_pid" ]; then
        kill "$watch_pid" 2>/dev/null
        wait "$watch_pid" 2>/dev/null
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf '  ok    %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "$1"
}
check() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted $2, got $3)"; fi
}

# Print the first ```bash fence appearing after a marker line. Fails loudly by printing
# nothing, which every caller asserts against — an extractor that silently returns empty
# would make every check below pass while measuring nothing.
extract_block() {
    awk -v marker="$2" '
        $0 ~ marker { seen = 1 }
        seen && /^```bash$/ { inb = 1; next }
        inb && /^```$/ { exit }
        inb { print }
    ' "$1"
}

# Is a background watch still running after it has had time to die? The broken form exits in
# milliseconds — the glob fails on the first pass, before the first sleep — so a one-second
# budget is two orders of magnitude of margin rather than a race. `alive` is asserted in BOTH
# directions below, so it cannot pass by always answering one way.
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }

printf '\nthe documented watch (helm-mail-cc/SKILL.md, "Arm")\n'

block=$(extract_block "$cc" '^Arm a background watch')
if [ -z "$block" ]; then
    bad "could not extract the Arm block from SKILL.md — every check below would be vacuous"
    printf '\n%s passed, %s failed\n' "$pass" "$fail"
    exit 1
fi
ok "the Arm block extracts from SKILL.md"

case "$block" in
*'for f in "$BOX"/*.json'*)
    bad "the Arm block is a bare glob again — see #237, and the header of this file"
    ;;
*) ok "the Arm block is not a bare glob" ;;
esac

# The doc's placeholder is `<your handle>`, which is what a reader replaces. Assert the
# substitution took: unsubstituted, `<your handle>` is a redirection under zsh and the watch
# would die for a reason that has nothing to do with the property under test.
mkdir -p "$tmp/box"
printf '%s\n' "$block" | sed "s|^BOX=.*|BOX=$tmp/box|" >"$tmp/watch.zsh"
if grep -q "^BOX=$tmp/box\$" "$tmp/watch.zsh"; then
    ok "the block's BOX line is where the reader substitutes their handle"
else
    bad "could not point the block at a temp box — the BOX= line changed shape"
fi

# THE acceptance criterion of #237: a mailbox directory containing no .json at all.
zsh "$tmp/watch.zsh" >"$tmp/watch.out" 2>&1 &
watch_pid=$!
sleep 1
check "survives a mailbox with no .json in it, under zsh" alive "$(alive "$watch_pid")"

# The negative control for the check above, and the reason it is not satisfied by a snippet
# that does nothing: the SAME harness, the same budget, against the form this issue removed.
# That glob is deliberately a frozen copy of the pre-#237 text — it is a historical artifact
# whose job is to fail, not a rule maintained in two places, so it must NOT be kept in step
# with SKILL.md if the documented watch changes again.
cat >"$tmp/broken.zsh" <<EOF
while true; do
  for f in "$tmp/box"/*.json; do
    [ -f "\$f" ] || continue
  done
  sleep 2
done
EOF
zsh "$tmp/broken.zsh" >/dev/null 2>&1 &
broken_pid=$!
sleep 1
check "the pre-#237 glob form dies on the same box (proves this harness can tell)" dead "$(alive "$broken_pid")"
kill "$broken_pid" 2>/dev/null

# Controls: these must pass either way. They fail if the fix OVERSHOOTS — a watch that
# survives an empty box by never reading the box at all would satisfy the check above and
# neither of these.
printf '{"handle":"x","runtime":"claude","pid":1,"sessionId":"s","cwd":"/tmp","claimedAt":0}\n' >"$tmp/box/owner.json"
printf '{"id":"1-a","from":"sender-9f2c","to":"x","subject":"s","body":"b","sentAt":1}\n' >"$tmp/box/1-a.json"
sleep 3
check "still delivers a message that arrives while it is running" \
    "MAIL sender-9f2c" "$(sed -n '1s/ —.*//p' "$tmp/watch.out")"
check "moves what it delivered into read/" "1-a.json" "$(ls "$tmp/box/read" 2>/dev/null)"
check "leaves owner.json alone" "owner.json" "$(ls "$tmp/box" | grep '^owner')"
check "is still running after delivering" alive "$(alive "$watch_pid")"

printf '\nthe documented send (both skills)\n'

# A send whose target directory is gone writes nothing, and both the python3 traceback and
# `mv: No such file or directory` land on stderr where a long tool result reads them as noise.
# The `||` is the line that says what it cost. Asserted as presence rather than by execution:
# proving that `||` fires on a nonzero exit is proving shell works, and running the block for
# real would mean pointing ~/.helm/mail somewhere else, which is a bigger rewrite of the doc
# than the property is worth.
for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    if grep -q 'mv "\$D/\.tmp-\$ID" "\$D/\$ID\.json"' "$f"; then
        ok "$name documents the atomic rename-in send"
        if grep -q 'mv "\$D/\.tmp-\$ID" "\$D/\$ID\.json" ||' "$f"; then
            ok "$name checks that send — a reaped mailbox cannot report success"
        else
            bad "$name has an unchecked mv — a send into a reaped mailbox reports success (#237)"
        fi
    else
        bad "$name no longer documents the send this gate knows how to check"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
