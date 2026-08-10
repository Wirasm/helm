#!/usr/bin/env bash
# Gate for push.sh. Needs bash and ps — nothing else, and deliberately not part of the
# Swift gate: `swift test` cannot run a shell script and should not learn how.
#
#   bash .claude/skills/helm-canvas/test.sh
#
# What it CANNOT prove: that the escape sequence reached a real helm and a pane appeared.
# That needs a running helm, and #184 exists because the instruction was verified by reading
# rather than by using — so run push.sh against a live helm before believing it.
#
# What it CAN prove, since #282, is which pty gets written to, and that is the part that used
# to be untested. Three staged cases pin one exit code each — a pty helm owns (0), a pty it
# does not (8), and no pty at all (6) — by handing push.sh the pty rather than observing
# whatever the gate happens to be run under, so the answers agree from a helm pane, from a
# Ghostty window and from CI.
#
# And it no longer DELIVERS while proving that. See the staging block below: this gate used
# to push six real artifacts onto the operator's own bench every run.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
push="$here/push.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() {
    local label=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s (wanted %s, got %s)\n' "$label" "$want" "$got"
    fi
}

# For the cases whose honest answer is a set rather than a number — see the note on
# `run_push`: which refusal comes back depends on whether whoever ran this gate had a
# controlling terminal, and both members mean "refused, emitted nothing".
check_one_of() {
    local label=$1 wanted=$2 got=$3
    case " $wanted " in
        *" $got "*)
            pass=$((pass + 1))
            printf '  ok    %s\n' "$label"
            ;;
        *)
            fail=$((fail + 1))
            printf '  FAIL  %s (wanted one of [%s], got %s)\n' "$label" "$wanted" "$got"
            ;;
    esac
}

check_contains() {
    local label=$1 needle=$2 haystack=$3
    case "$haystack" in
        *"$needle"*)
            pass=$((pass + 1))
            printf '  ok    %s\n' "$label"
            ;;
        *)
            fail=$((fail + 1))
            printf '  FAIL  %s (missing %s): %s\n' "$label" "$needle" "$haystack"
            ;;
    esac
}

# --- the gate for a delivery mechanism must not itself deliver --------------------------
#
# It did, for as long as it existed. Six cases ran push.sh straight from the gate's own
# process tree, and an agent runs this gate from inside a helm pane — so every run wrote a
# real OSC into the OPERATOR'S terminal: five times for the extension loop, once more for
# the probe, each leaving a canvas tab onto a `mktemp` directory this file then deleted on
# exit. He watched a row of dead `a.md` tabs pile up while #282 was being fixed.
#
# That is #282 wearing the other face, and a better argument for the guard than the one the
# issue opens with because it happened rather than being hypothetical: push.sh resolved *a*
# pty rather than the intended one, and nothing about the call said which bench was meant.
#
# **So the guarantee is built rather than remembered.** `$push` is named on exactly ONE line
# in this file — the runner heredoc below — and everything goes through it. The first fix
# here staged each emitting case individually, which removed that day's instances and left
# the bug: `run_code` still invoked push.sh raw, every caller merely happened to refuse on
# 2-5 or 7 before `resolve_sink` ran, and nothing made that true by construction. The next
# case added beside push.sh's hand-kept extension list is the one that reaches for the
# obvious helper with a renderable path and puts six artifacts back on his bench.
#
# `run_push` is detached, so it cannot resolve a live pty whatever it is handed. The two
# cases that must be given a pty say so at the call site and are visibly the exception.

# $1 exit-code file, $2 stdout+stderr file, rest are push.sh's own arguments. Sending stdout
# to a FILE is also the #184 shape — the caller's stdout is not a terminal, as under a
# harness. THIS IS THE ONLY LINE IN THIS FILE THAT INVOKES push.sh; the check near the end
# fails the run if that stops being true.
cat >"$tmp/push-run" <<EOF
#!/usr/bin/env bash
code_file=\$1
out_file=\$2
mode=\$3
shift 3

# The reparent to pid 1 is what makes delivery impossible, and it RACES this script's own
# startup: \`( ( cmd & ) & )\` only reparents once the intermediate shell exits, which can be
# after the grandchild is already running. A run that proceeds while still attached is
# precisely the one whose walk can reach the operator's helm — so wait for the reparent, and
# refuse rather than proceed without it. Exit 99 is this runner's own, not push.sh's.
if [ "\$mode" = detached ]; then
    waited=0
    while [ "\$(ps -o ppid= -p \$\$ | tr -d ' ')" != "1" ]; do
        if [ \$waited -ge 300 ]; then
            printf 'gate runner: never reparented, refusing to invoke push.sh\n' >"\$out_file"
            printf '99' >"\$code_file"
            exit 99
        fi
        sleep 0.01
        waited=\$((waited + 1))
    done
fi

"$push" "\$@" >"\$out_file" 2>&1
printf '%s' \$? >"\$code_file"
EOF

# `</dev/null` is load-bearing: script(1) tcgetattr's its own stdin, and nested inside an
# agent's tool call that is a SOCKET — "Operation not supported on socket", no pty, no code
# file. It ran fine by hand, which is the same trap this whole file is about.
detach() { ( ( "$@" >/dev/null 2>&1 </dev/null & ) & ); }

await_code() {
    local out=$1 waited=0 max_wait=100 # 100 * 0.1s = a 10s ceiling
    while [ ! -f "$out" ] && [ "$waited" -lt "$max_wait" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    cat "$out" 2>/dev/null
}

run_status=""
run_output=""

# **Why the double fork makes this safe, precisely.** It does NOT remove the terminal: a
# controlling tty is inherited across fork and reparenting does not clear it, so a run
# launched from a shell that has one still reports that tty to `ps`. What it removes is the
# ANCESTRY — ppid becomes 1 — and push.sh needs the ancestry to decide, because `pty_owner`
# identifies a pty by walking up from it until the tty changes. With the chain cut at pid 1
# there is no owner to find, so the tty can never be proved helm's and the run can never
# deliver. Measured both ways below in `#282`'s own red/green pair.
#
# The consequence, and the reason the cases below assert what they assert: the exact
# refusal depends on whether whoever ran this gate had a controlling terminal. Headless — an
# agent's tool call, CI — it is `6`, nothing reachable. From the operator's own shell it is
# `8`, a terminal that cannot be shown to be helm's. Both are refusals that emit nothing,
# which is the invariant; asserting one of the two numbers would fail for half the people
# who run this file, and did in an earlier draft.
run_push() {
    rm -f "$tmp/rc" "$tmp/out"
    detach bash "$tmp/push-run" "$tmp/rc" "$tmp/out" detached "$@"
    run_status=$(await_code "$tmp/rc")
    run_output=$(cat "$tmp/out" 2>/dev/null)
}

# Most cases want only the code.
run_code() {
    run_push "$@"
    printf '%s' "$run_status"
}

printf 'push.sh\n'

# --- refusals, each with its own code so a caller can act on it -------------------------
check "no arguments"          2 "$(run_code)"
check "two arguments"         2 "$(run_code /a.md /b.md)"
check "relative path"         3 "$(run_code relative.md)"
check "tilde path"            3 "$(run_code '~/plan.md')"
check "missing file"          4 "$(run_code /nonexistent/plan.md)"

printf 'body\n' >"$tmp/artifact.zip"
check "unrenderable extension" 5 "$(run_code "$tmp/artifact.zip")"
printf 'body\n' >"$tmp/noext"
check "no extension at all"    5 "$(run_code "$tmp/noext")"

# --- refusals say something actionable --------------------------------------------------
run_push "$tmp/artifact.zip"
check_contains "refusal names the offending extension" "zip" "$run_output"
run_push "$tmp/noext"
check_contains "a dotless path is described as such" "no extension" "$run_output"

# --- a path that would inject a second escape sequence ---------------------------------
# Only NUL and `/` are forbidden in a Unix path, so ESC is legal in a filename — and
# splicing one into an OSC hands the terminal an attacker-chosen sequence of its own.
evil=$(printf '%s/eviltitle\033]0;PWNED\007.md' "$tmp")
: >"$evil" 2>/dev/null && {
    run_push "$evil"
    check "a path carrying control bytes is refused" 7 "$run_status"
    check_contains "and says why" "control characters" "$run_output"
}

# --- the renderable extensions are all accepted -----------------------------------------
# `6 8` is the exhaustive set of honest answers here and says three things at once: not 5,
# so the extension was accepted; not 0, so nothing was delivered; and not 99, so the runner
# really did reparent before it ran.
for ext in md markdown mdown html htm; do
    printf 'x\n' >"$tmp/a.$ext"
    run_push "$tmp/a.$ext"
    check_one_of ".$ext is renderable, and undelivered" "6 8" "$run_status"
done

# --- refused, and the caller still gets the path -----------------------------------------
printf '# probe\n' >"$tmp/probe.md"
run_push "$tmp/probe.md"
# Printed on delivery, and named in both refusals — so the operator has the path either way.
check_contains "the path is printed for the operator" "$tmp/probe.md" "$run_output"

# --- the construction, checked ----------------------------------------------------------
# THE CASE THAT MAKES THE INVARIANT REAL RATHER THAN CONVENTIONAL, and the one that fails if
# anyone reverts the runner to a raw call. `run_push` is handed the single thing that gets
# past every refusal — a real, renderable, absolute path — and must still not deliver.
#
# `6 8` excludes 0 — "the bytes went somewhere" — which is the thing that must never happen
# from this file, and excludes 99, the runner refusing because it was still attached.
# Measured against a runner sabotaged back to calling push.sh directly, run inside a
# captured helm-named pty: every one of these came back 0 and 14 ESC bytes — seven real
# deliveries — landed in that pty. From an agent, that pty is the operator's bench.
run_push "$tmp/probe.md"
check_one_of "the gate's own runner never delivers, given a renderable path" "6 8" "$run_status"

# And the other half: nothing may invoke push.sh except that runner. `run_code` is the
# obvious helper to reach for and it used to call push.sh directly, which was harmless only
# because every caller happened to refuse before sink resolution. The pattern is written so
# it cannot match this line.
check "push.sh is invoked from exactly one line in this file" 1 \
    "$(grep -c '"[$]push"' "$0")"

# --- which pty, which exit code (#282) --------------------------------------------------
# The case above is one exit code out of three that mean "not refused for its extension", so
# on its own it is satisfied by refusing everything — the failure mode opposite to the one
# being fixed, and just as silent. These two pin the other half, one exit code each, by
# STAGING the pty rather than observing whatever the gate happens to be run under.
#
# Both are detached for the reason at the top of the file, and detaching is also what makes
# them mean anything: without it, a `script` pty started from a pane is correctly walked PAST
# to the pane's own pty and both would come back 0 — which is exactly how the previous
# version of this check ended up asserting the bug. It wrapped push.sh in `script`, got the 0
# it expected, and could not tell "found a pty" from "found helm's".
if command -v script >/dev/null 2>&1; then
    rm -f "$tmp/c_helm" "$tmp/c_foreign" "$tmp/ts"

    # These two are the deliberate exception to "detached, so no pty" — they run the SAME
    # runner, under a pty staged for them, and each pty's stream is disposed of at the call
    # site rather than left to reach anyone.
    #
    # `exec -a helm` makes the pty's owning process report as `helm` to `ps`, which is the
    # whole of what push.sh asks. Copying script(1) to a file named `helm` is the obvious
    # alternative and does not work — the copy loses its Apple signature and macOS answers
    # `Killed: 9` (measured). The pty's own stream goes to /dev/null, so the emit this case
    # provokes is real and lands nowhere.
    # `attached` because these two MUST keep the ancestry to the pty staged for them — it is
    # the thing under test. Their safety comes from the pty being staged and its stream
    # disposed of here, not from the reparent.
    detach bash -c 'exec -a helm script -q /dev/null bash "$0" "$1" "$2" "$3" "$4"' \
        "$tmp/push-run" "$tmp/c_helm" "$tmp/out_helm" attached "$tmp/probe.md"
    # A real pty, no helm anywhere above it: the Ghostty teammate of #282. Its stream is
    # captured to a file, so the next check can read what did or did not reach it.
    detach script -q "$tmp/ts" \
        bash "$tmp/push-run" "$tmp/c_foreign" "$tmp/out_foreign" attached "$tmp/probe.md"

    # THE CONTROL AGAINST OVERSHOOT. A fix that simply refuses more passes the negative
    # cases and fails this one. It needs no running helm — only a pty whose owner answers to
    # the name — so it holds in CI, and it never touches the operator's bench.
    check "a pty helm owns is delivered to"          0 "$(await_code "$tmp/c_helm")"

    # THE NEGATIVE CONTROL, and the whole of #282: a terminal that is not helm's.
    check "a pty helm does not own is refused"       8 "$(await_code "$tmp/c_foreign")"

    # Refusing has to be silent on the wire, not merely nonzero — the damage in #282 was an
    # escape sequence written into a terminal that never asked for one. Counting ESC bytes
    # rather than grepping for the marker keeps this honest if the marker is ever renamed.
    check "and emits no escape sequence into it"     0 \
        "$(LC_ALL=C tr -dc '\033' <"$tmp/ts" 2>/dev/null | wc -c | tr -d ' ')"
else
    printf '  skip  no script(1) — cannot stage a pty here\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
