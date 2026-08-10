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

run_code() {
    "$push" "$@" >/dev/null 2>&1
    printf '%s' $?
}

# --- staging, so the gate for a delivery mechanism does not itself deliver ---------------
#
# Every case that gets past the extension check reaches push.sh's emit — and an agent runs
# this gate from inside a helm pane, so those cases used to write a real OSC into the
# OPERATOR'S terminal: five times for the extension loop, once more for the probe, each
# leaving a canvas tab pointing into a `mktemp` directory this file then deleted on exit.
# He watched a row of dead `a.md` tabs pile up while #282 was being fixed.
#
# That is #282 wearing the other face, and a better argument for the guard than the one the
# issue opens with because it happened rather than being hypothetical: push.sh resolved *a*
# pty rather than the intended one, and nothing about the call said which bench was meant.
#
# So every emitting case is staged. `detach` double-forks, which reparents to pid 1 and cuts
# the ancestor chain — the answer then does not depend on where the gate is run (a pane, a
# Ghostty window and CI all agree) and nothing can reach the operator. The one case that has
# to prove a REAL emit gives push.sh a pty of its own instead, so the bytes land in a
# captured stream rather than on a bench; that needs no live helm and no disposable
# `HELM_DEFAULTS_SUITE` instance to keep clean.
#
# `</dev/null` is load-bearing: script(1) tcgetattr's its own stdin, and nested inside an
# agent's tool call that is a SOCKET — "Operation not supported on socket", no pty, no code
# file. It ran fine by hand, which is the same trap this whole file is about.

# $1 exit-code file, $2 artifact, $3 file for stdout+stderr. Sending stdout to a FILE is
# also the #184 shape — the caller's stdout is not a terminal, exactly as under a harness.
cat >"$tmp/run" <<EOF
#!/usr/bin/env bash
"$push" "\$2" >"\$3" 2>&1
printf '%s' \$? >"\$1"
EOF

detach() { ( ( "$@" >/dev/null 2>&1 </dev/null & ) & ); }

await_code() {
    local out=$1 waited=0 max_wait=100 # 100 * 0.1s = a 10s ceiling
    while [ ! -f "$out" ] && [ "$waited" -lt "$max_wait" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    cat "$out" 2>/dev/null
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
check_contains "refusal names the offending extension" "zip" \
    "$("$push" "$tmp/artifact.zip" 2>&1 >/dev/null)"
check_contains "a dotless path is described as such" "no extension" \
    "$("$push" "$tmp/noext" 2>&1 >/dev/null)"

# --- a path that would inject a second escape sequence ---------------------------------
# Only NUL and `/` are forbidden in a Unix path, so ESC is legal in a filename — and
# splicing one into an OSC hands the terminal an attacker-chosen sequence of its own.
evil=$(printf '%s/eviltitle\033]0;PWNED\007.md' "$tmp")
: >"$evil" 2>/dev/null && {
    check "a path carrying control bytes is refused" 7 "$(run_code "$evil")"
    check_contains "and says why" "control characters" "$("$push" "$evil" 2>&1 >/dev/null)"
}

# --- the renderable extensions are all accepted -----------------------------------------
# Staged with no pty anywhere, so each is 6 on any machine and none of them emits. What the
# case is about is the extension being ACCEPTED — anything but 5 — and 6 is the proof it got
# all the way to sink resolution. Launched together, then collected, so five detached runs
# cost one wait rather than five.
for ext in md markdown mdown html htm; do
    printf 'x\n' >"$tmp/a.$ext"
    detach bash "$tmp/run" "$tmp/rc.$ext" "$tmp/a.$ext" "$tmp/out.$ext"
done
for ext in md markdown mdown html htm; do
    check ".$ext is renderable" 6 "$(await_code "$tmp/rc.$ext")"
done

# --- no pty at all: refused, and the caller still gets the path --------------------------
printf '# probe\n' >"$tmp/probe.md"
detach bash "$tmp/run" "$tmp/c_none" "$tmp/probe.md" "$tmp/out_none"
check "no pty at all is refused, nothing emitted" 6 "$(await_code "$tmp/c_none")"
# Printed on delivery, and named in both refusals — so the operator has the path either way.
check_contains "the path is printed for the operator" "$tmp/probe.md" \
    "$(cat "$tmp/out_none" 2>/dev/null)"

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

    # `exec -a helm` makes the pty's owning process report as `helm` to `ps`, which is the
    # whole of what push.sh asks. Copying script(1) to a file named `helm` is the obvious
    # alternative and does not work — the copy loses its Apple signature and macOS answers
    # `Killed: 9` (measured). The pty's own stream goes to /dev/null, so the emit this case
    # provokes is real and lands nowhere.
    detach bash -c 'exec -a helm script -q /dev/null bash "$0" "$1" "$2" "$3"' \
        "$tmp/run" "$tmp/c_helm" "$tmp/probe.md" "$tmp/out_helm"
    # A real pty, no helm anywhere above it: the Ghostty teammate of #282. Its stream is
    # captured, so the next check can read what did or did not reach it.
    detach script -q "$tmp/ts" bash "$tmp/run" "$tmp/c_foreign" "$tmp/probe.md" "$tmp/out_foreign"

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
