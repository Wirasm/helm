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

# Run a documented snippet under zsh — the shell Claude Code's own Bash tool runs — with the two
# variables that MOVE THE MAILROOM taken out of the environment first (#285).
#
# Not tidiness: since #285 the snippets resolve their root through
# `${HELM_MAIL_DIR:-~/.helm/mail${HELM_DEFAULTS_SUITE:+-$HELM_DEFAULTS_SUITE}}`, and this gate is
# very often run by an agent hosted in an isolated helm, which exports exactly the second one. The
# checks below point the snippet at a temp root by rewriting the literal inside that expression, so
# an inherited `HELM_MAIL_DIR` would beat the rewrite outright and an inherited suite would append
# to it — either way the snippet reads a directory this file never wrote to, and every assertion
# about what it printed becomes an assertion about an empty directory. `resolves_root` below tests
# the expression itself, with these set on purpose.
run_zsh() { env -u HELM_MAIL_DIR -u HELM_DEFAULTS_SUITE zsh "$@"; }

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
run_zsh "$tmp/watch.zsh" >"$tmp/watch.out" 2>&1 &
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
run_zsh "$tmp/broken.zsh" >/dev/null 2>&1 &
broken_pid=$!
sleep 1
check "the pre-#237 glob form dies on the same box (proves this harness can tell)" dead "$(alive "$broken_pid")"
kill "$broken_pid" 2>/dev/null

# Controls: these must pass either way. They fail if the fix OVERSHOOTS — a watch that
# survives an empty box by never reading the box at all would satisfy the check above and
# neither of these.
printf '{"handle":"x","runtime":"claude","pid":1,"sessionId":"s","cwd":"/tmp","claimedAt":0}\n' >"$tmp/box/owner.json"
printf '{"id":"1-a","from":"sender-9f2c","to":"x","subject":"s","body":"b","sentAt":1}\n' >"$tmp/box/1-a.json"
# 4s against the watch's own `sleep 2`, so a full poll cycle plus a python3 spawn fits twice over.
# 3 was enough on an idle machine and left about a second of slack; several agents sharing this
# box is the normal state here, and a gate that goes red under load teaches people to re-run it.
sleep 4
check "still delivers a message that arrives while it is running" \
    "MAIL sender-9f2c" "$(sed -n '1s/ —.*//p' "$tmp/watch.out")"
check "moves what it delivered into read/" "1-a.json" "$(ls "$tmp/box/read" 2>/dev/null)"
check "leaves owner.json alone" "owner.json" "$(ls "$tmp/box" | grep '^owner')"
check "is still running after delivering" alive "$(alive "$watch_pid")"

printf '\nthe documented mail root (both skills, #285)\n'

# WHICH MAILROOM THE DOC SENDS AN AGENT TO, executed rather than read.
#
# `HELM_DEFAULTS_SUITE` moves the mailbox: an agent hosted by an isolated helm claims in
# `~/.helm/mail-<suite>` and the operator's `~/.helm/mail` holds his own live agents (#285). Before
# this, every snippet in these two files named `~/.helm/mail` outright and a paragraph above them
# asked the reader to remember the substitution — so an agent in a throwaway instance that followed
# the block literally would LIST and SEND INTO his mailroom, successfully and silently. That is the
# cross-talk the code fix exists to close, reintroduced by the documentation of the fix.
#
# So the root is a value the snippets resolve, and this is the check that it resolves to the right
# directory. Extracted from the doc rather than retyped, for this file's founding reason: a test
# that restates the expression is a second copy of it and would keep passing while the doc said
# something else.
#
# The WHOLE preamble is taken, not just its last line. The `case` line is what refuses the three
# names that are not a suite, and a check that lifted only `ROOT=` would run it with `$SUITE`
# unset — which resolves the shared root for every input and would pass every row below while
# measuring nothing at all.
root_expr=$(extract_block "$cc" '^\*\*Every snippet below opens')
if [ -z "$root_expr" ]; then
    bad "could not extract the root preamble from helm-mail-cc/SKILL.md — every check below would be vacuous"
elif [ "$(extract_block "$pi" '^\*\*Every snippet below opens')" != "$root_expr" ]; then
    # The two skills are documented identically by design, which is why one gate covers both; a
    # root that diverged would put the two runtimes in different mailrooms.
    bad "helm-mail-pi's root preamble differs from helm-mail-cc's"
else
    ok "both skills state one root preamble, and it is the same one"
fi

# …and every snippet in both files must open with all of it, which is the failure the extraction
# above cannot see: a block that kept `ROOT=` and dropped the `case` line is exactly the leak, and
# it would sit in a file whose stated preamble is still correct.
for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    counts=$(while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -Fxc -- "$line" "$f"
    done <<EOF
$root_expr
EOF
    )
    if [ "$(printf '%s\n' "$counts" | sort -u | wc -l | tr -d ' ')" = 1 ]; then
        ok "$name repeats the whole preamble in every snippet ($(printf '%s\n' "$counts" | head -1) of each line)"
    else
        bad "$name has snippets carrying only part of the preamble: line counts $(printf '%s' "$counts" | tr '\n' ' ')"
    fi
done

resolves_root() {
    printf '%s\nprintf "%%s" "$ROOT"\n' "$root_expr" >"$tmp/root.zsh"
    env -u HELM_MAIL_DIR -u HELM_DEFAULTS_SUITE HOME="$tmp/fakehome" $1 zsh "$tmp/root.zsh"
}
check "with no suite, the doc reads the operator's own mailroom" \
    "$tmp/fakehome/.helm/mail" "$(resolves_root "")"
check "inside an isolated helm, it reads that instance's mailroom instead (#285)" \
    "$tmp/fakehome/.helm/mail-drivetest" "$(resolves_root "HELM_DEFAULTS_SUITE=drivetest")"
check "and an explicit HELM_MAIL_DIR still beats both, or no test could redirect one" \
    "/tmp/somewhere-else" "$(resolves_root "HELM_MAIL_DIR=/tmp/somewhere-else")"

# THE THREE NAMES THAT ARE NOT A SUITE, and they are the whole reason this group exists rather
# than being three rows of the same thing.
#
# The real writers refuse all three — `DefaultsSuite.override` maps the canonical domain to
# `.none` and the other two to `.refused`, and `mailRoot()` sends every one of them to the SHARED
# root. A documented expression that honoured them anyway is a silent, one-way leak in the
# direction that costs most: a session whose mailbox was correctly claimed at `~/.helm/mail` by the
# real hook reads an empty `~/.helm/mail-<name>`, sends into it "successfully", and watches a box
# nothing will ever deliver to. No error on any path.
#
# And `com.wirasm.helm` is not an exotic value. It is the literal `AGENTS.md` tells contributors to
# `defaults read`, helm LAUNCHES NORMALLY under it — `.none`, not `.refused`, so nothing stops it —
# and `claude-session-start` fires for every Claude Code session on this machine, helm pane or not.
# `helm` is both the obvious guess at a suite name and the legacy domain anyone testing the refusal
# would export. The fixtures are the same two strings `MAIL_ROOT_CASES` and
# `MailboxDirectoryTests.testTheSuiteMovesTheMailroomOnlyWhenHelmWouldHonourIt` run against the
# real implementation, on purpose: this is that check, one language over.
check "naming the canonical domain is naming no suite, here as in helm" \
    "$tmp/fakehome/.helm/mail" "$(resolves_root "HELM_DEFAULTS_SUITE=com.wirasm.helm")"
check "and so is the legacy domain helm refuses to run under" \
    "$tmp/fakehome/.helm/mail" "$(resolves_root "HELM_DEFAULTS_SUITE=helm")"
check "and a name with a path in it, which this doc would otherwise mkdir into" \
    "$tmp/fakehome/.helm/mail" "$(resolves_root "HELM_DEFAULTS_SUITE=path/with/slash")"

printf '\nthe documented mailbox listing (both skills)\n'

# The OTHER glob. `for f in ~/.helm/mail/*/owner.json` is the same fatal-under-zsh shape as the
# watch was, and it was left in place on the first pass of #237 on the argument that a foreground
# one-shot fails loudly where a background watch fails silently. That is true and it is still not
# a reason to keep a dialect trap in a file being edited to remove one — a review caught it.
# Executed rather than grepped, because the failure is what matters and the empty root is the case.
mkdir -p "$tmp/emptyroot"
for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    listing=$(extract_block "$f" '^## Who is reachable')
    if [ -z "$listing" ]; then
        bad "$name — could not extract the 'Who is reachable' block"
        continue
    fi
    printf '%s\n' "$listing" | sed "s|~/.helm/mail|$tmp/emptyroot|g" >"$tmp/listing.zsh"
    run_zsh "$tmp/listing.zsh" >/dev/null 2>&1
    check "$name lists reachable agents without dying on a mail root with none" 0 "$?"
done

# The control for the two above: it must still print the rows when there ARE mailboxes. A listing
# that survives an empty root by listing nothing ever would pass the checks above and fail this.
#
# The owner here is VALID JSON missing an optional field — the shape every mailbox claimed before
# `retiredAt` existed has, and the shape a fragment has. It must come out as a row saying `dead`,
# because a mailbox with no pid is a mailbox nobody can be shown to be listening to. Genuinely
# unparseable JSON is a different case and is checked separately, below.
mkdir -p "$tmp/emptyroot/a-1111"
printf '{"handle":"a-1111"}\n' >"$tmp/emptyroot/a-1111/owner.json"
printf '%s\n' "$(extract_block "$cc" '^## Who is reachable')" | sed "s|~/.helm/mail|$tmp/emptyroot|g" >"$tmp/listing.zsh"
check "and still prints a mailbox that is there" \
    'dead {"handle": "a-1111"}' "$(run_zsh "$tmp/listing.zsh" 2>/dev/null)"

printf '\nretired mailboxes in the documented listing (both skills)\n'

# #236 changed a dead mailbox from DELETED to RETIRED: reaping rewrites `owner.json` with a
# `retiredAt` and leaves the directory and its `read/` where they are. Both skills went on
# teaching `kill -0 <pid>` as THE liveness test, which cannot see that — a retired owner's pid
# may well still be alive (the `/clear` ghost's is, and the kernel reuses pids), so the pid alone
# calls a mailbox nobody is listening to perfectly healthy. That is #248, and an agent following
# the documented procedure sends into it and gets silence.
#
# So the listing is run against all four corners of retired × pid-alive, and the ORDER of the two
# checks is what `retired-live` and `retired-dead` pin down. Executed rather than grepped for the
# same reason as everything else in this file: a grep proves the word `retiredAt` is in the doc,
# not that the snippet beside it acts on the field.
#
# The owner.json files are written here rather than by `hooks/helm-mail.mjs`, because this gate
# needs only bash, zsh and python3 and adding node to it would make every contributor need node —
# see the header, and AGENTS.md on the Swift gate for the same rule. The shape they copy is
# `writeAtomic`'s payload in `hooks/helm-mail.mjs` and `Owner` in
# `pi/extensions/helm-mail/index.ts`, checked by hand against a mailbox the real hook had
# actually retired. THIS IS A THIRD SITE for that shape and neither of the other two names it:
# if either grows a field the listing's verdict depends on, `owner_file` below is where this gate
# has to learn it. What it depends on today is `pid` and `retiredAt`, and nothing else.

# One pid that is certainly alive and one that is certainly dead, both established by this run —
# so neither is a guess about what the machine happens to be doing at the time. `$$` is this
# script, which is alive for as long as there is anyone to ask; the other is a child that has
# already been reaped, and macOS hands out pids sequentially, so it will not come back during
# the second this takes.
live_pid=$$
(exit 0) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null

# <root> <handle> <pid> <retiredAt, or empty for a live claim>
owner_file() {
    mkdir -p "$1/$2"
    python3 -c '
import json, sys
o = {"handle": sys.argv[1], "runtime": "claude", "pid": int(sys.argv[2]),
     "sessionId": "s-" + sys.argv[1], "cwd": "/tmp/w/" + sys.argv[1], "claimedAt": 1786028945735}
if sys.argv[3]:
    o["retiredAt"] = int(sys.argv[3])
json.dump(o, open(sys.argv[4], "w"), indent=2)' "$2" "$3" "$4" "$1/$2/owner.json"
}
owner_file "$tmp/states" boxlive "$live_pid" ""
owner_file "$tmp/states" boxdead "$dead_pid" ""
owner_file "$tmp/states" boxretlive "$live_pid" 1786045284085
owner_file "$tmp/states" boxretdead "$dead_pid" 1786045284086

# The state the listing put in front of the word `{`, for one handle. Anchored on the quotes so
# `boxlive` cannot match `s-boxlive` or `/tmp/w/boxlive` on some other row's line.
state_of() { printf '%s\n' "$2" | grep -F "\"$1\"" | awk '{print $1}'; }

for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    printf '%s\n' "$(extract_block "$f" '^## Who is reachable')" | sed "s|~/.helm/mail|$tmp/states|g" >"$tmp/listing.zsh"
    out=$(run_zsh "$tmp/listing.zsh" 2>/dev/null)

    # The acceptance criterion of #248. The pid is alive, so anything asking the pid first says
    # `live` about a mailbox that will never be read again.
    check "$name marks a retired mailbox whose pid is still alive as retired" \
        retired "$(state_of boxretlive "$out")"
    # And the order, from the other side: with a dead pid both fields point the same way, so a
    # `dead` here means the pid was reached first and `retiredAt` was never asked.
    check "$name marks a retired mailbox whose pid is dead as retired, not dead" \
        retired "$(state_of boxretdead "$out")"

    # CONTROL — must pass either way, and fails if the fix overshoots by calling everything
    # retired. A listing that marked every row retired would satisfy both checks above.
    check "$name still marks a live mailbox live" live "$(state_of boxlive "$out")"
    # CONTROL — the pid check must SURVIVE. Reaping only runs when some agent starts a session,
    # so an idle machine keeps dead owners with no `retiredAt` on them, and `retiredAt` alone
    # would call this one live.
    check "$name still marks a dead pid with no retiredAt as dead" dead "$(state_of boxdead "$out")"
    # CONTROL — retired rows are SHOWN, not filtered out. Hiding them throws away the whole
    # argument for retiring instead of deleting: a sender holding an old handle learns "that
    # agent is gone" rather than "no such handle".
    check "$name shows all four mailboxes, retired ones included" 4 \
        "$(printf '%s\n' "$out" | grep -c '"handle"')"
done

printf '\nan owner.json that will not parse (both skills)\n'

# The listing PARSES owner.json now, where `-exec cat` never did, so a half-written or hand-edited
# file is a case the old form did not have. Unguarded it is a python traceback on stderr and NO row
# at all — the mailbox silently leaves the answer to "who is reachable", which is the worst of the
# three possible behaviours. It must be a row that says so, the way pi's `peers()` prints
# `no owner.json` rather than dropping the handle.
mkdir -p "$tmp/broken/torn-0001"
printf '{"handle":"torn-0001","runtime":"clau' >"$tmp/broken/torn-0001/owner.json"
owner_file "$tmp/broken" intact-0002 "$live_pid" ""

for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    printf '%s\n' "$(extract_block "$f" '^## Who is reachable')" | sed "s|~/.helm/mail|$tmp/broken|g" >"$tmp/listing.zsh"
    out=$(run_zsh "$tmp/listing.zsh" 2>/dev/null)
    check "$name reports an unparseable owner.json instead of dropping it" \
        unreadable "$(printf '%s\n' "$out" | grep -F torn-0001 | awk '{print $1}')"
    # CONTROL — must pass either way, and is what says the check above is not satisfied by a
    # listing that has simply died. One bad mailbox must not cost the good ones.
    check "$name still lists the mailbox beside it" live "$(state_of intact-0002 "$out")"
done

printf '\nthe documented send into a RETIRED mailbox (both skills)\n'

# The new paragraph in both Sending sections claims the `||` guard cannot see a retired mailbox:
# the directory is deliberately still there, so the rename succeeds and reports success while
# nobody will ever read the file. Everything else in this gate is executed rather than asserted,
# and that claim should not be the exception — it is the precise reason #248 matters.
#
# So this is a TRIPWIRE rather than a bug hunt: it passes today and it is meant to. It goes red the
# day the documented send grows a `retiredAt` check of its own — at which point the paragraph
# beside it is wrong and has to change with it.
for f in "$cc" "$pi"; do
    name=$(basename "$(dirname "$f")")
    box="sendret-$name"
    owner_file "$tmp/sendroot" "$box" "$live_pid" 1786045284085

    # `<your handle>` and the example `TO=` are what a reader replaces. Left in place, `<your
    # handle>` is a redirection under zsh and the send would die for a reason that has nothing to
    # do with the property under test — the same trap the Arm block guards against above.
    printf '%s\n' "$(extract_block "$f" '^## Sending')" |
        sed -e "s|^TO=.*|TO=$box; FROM=gate-0000|" -e "s|~/.helm/mail|$tmp/sendroot|g" >"$tmp/send.zsh"
    if grep -q "^TO=$box; FROM=gate-0000\$" "$tmp/send.zsh"; then
        ok "$name — the send block's TO/FROM line is where the reader substitutes"
    else
        bad "$name — could not point the send block at a temp box; the TO= line changed shape"
    fi

    sent=$(run_zsh "$tmp/send.zsh" 2>/dev/null)
    check "$name — the send REPORTS SUCCESS into a retired mailbox" "" "$sent"
    check "$name — and the message really did land there, unread" 1 \
        "$(find "$tmp/sendroot/$box" -maxdepth 1 -name '*.json' ! -name owner.json -type f | wc -l | tr -d ' ')"
done

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
