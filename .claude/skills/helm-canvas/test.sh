#!/usr/bin/env bash
# Gate for push.sh. Needs bash and ps — nothing else, and deliberately not part of the
# Swift gate: `swift test` cannot run a shell script and should not learn how.
#
#   bash .claude/skills/helm-canvas/test.sh
#
# What it CANNOT prove: that the escape sequence reached helm and a pane appeared. That
# needs a running helm and an agent to run it from, and it is the check that matters most
# (#184 exists because the instruction was verified by reading rather than by using). So
# the last case here emits for real and asserts only that delivery was attempted and
# reported success — the operator confirms the pane.
#
# What it CAN prove, since #282, is which pty gets written to, and that is the part that
# used to be untested. The three staged cases at the bottom give push.sh a pty helm owns, a
# pty it does not, and no pty at all, and pin one exit code to each. They are staged rather
# than observed so the gate answers the same from a helm pane and from CI.

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
for ext in md markdown mdown html htm; do
    printf 'x\n' >"$tmp/a.$ext"
    code=$(run_code "$tmp/a.$ext")
    # Past the extension gate, so anything but 5 means the extension was accepted. Which of
    # 0/6/8 comes back depends on where the gate is being run — a helm pane, a Ghostty
    # window, or CI — and that is the staged trio's job below, not this one's.
    case "$code" in
        0 | 6 | 8) pass=$((pass + 1)); printf '  ok    .%s is renderable\n' "$ext" ;;
        *) fail=$((fail + 1)); printf '  FAIL  .%s rejected with %s\n' "$ext" "$code" ;;
    esac
done

# --- delivery, for real ------------------------------------------------------------------
# The case #184 is about: run from a context whose stdout is NOT a terminal, which is what
# an agent's tool call looks like. Piping to cat is exactly that.
printf '# probe\n' >"$tmp/probe.md"
out=$("$push" "$tmp/probe.md" 2>&1 | cat)
code=${PIPESTATUS[0]:-0}
# Printed on delivery, and named in both refusals — so the operator has the path either way.
check_contains "the path is printed for the operator" "$tmp/probe.md" "$out"
case "$code" in
    0) pass=$((pass + 1)); printf '  ok    delivered with stdout captured\n' ;;
    6) pass=$((pass + 1)); printf '  ok    refused loudly — no pty here, nothing emitted\n' ;;
    8) pass=$((pass + 1)); printf '  ok    refused loudly — pty is not helm'"'"'s, nothing emitted\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  unexpected exit %s with stdout captured\n' "$code" ;;
esac

# --- which pty, which exit code (#282) --------------------------------------------------
# The case above accepts 0, 6 OR 8, so on its own it is satisfied by refusing everything —
# which is the failure mode opposite to the one being fixed, and just as silent. These
# three pin it, one exit code each, by STAGING the pty rather than observing whatever the
# gate happens to be run under.
#
# The double-fork is the load-bearing part of each. It reparents the run to pid 1 and cuts
# the ancestor chain, so the answer does not depend on the gate itself running inside a
# helm pane. Without it, a `script` pty started from a pane is correctly walked PAST to the
# pane's own pty and every case here would come back 0 — which is exactly how the previous
# version of this check ended up asserting the bug: it wrapped push.sh in `script`, got the
# 0 it expected, and could not tell "found a pty" from "found helm's".
#
# `</dev/null` is load-bearing too: script(1) tcgetattr's its own stdin, and nested inside
# an agent's tool call that is a SOCKET — "Operation not supported on socket", no pty, no
# code file. It ran fine by hand, which is the same trap this whole file is about.
if command -v script >/dev/null 2>&1; then
    # One runner, so the three cases below differ only in the pty they are handed and not
    # in three layers of shell quoting. $1 is where the exit code goes — a FILE, because
    # under `script` the pty stream is captured too and parsing a status out of it would
    # mean parsing around the very escape sequence under test.
    cat >"$tmp/run" <<EOF
#!/usr/bin/env bash
"$push" "$tmp/probe.md" >/dev/null 2>&1
printf '%s' \$? >"\$1"
EOF

    detach() { ( ( "$@" >/dev/null 2>&1 </dev/null & ) & ); }

    await_code() {
        local out=$1 waited=0
        while [ ! -f "$out" ] && [ "$waited" -lt 100 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        cat "$out" 2>/dev/null
    }

    rm -f "$tmp/c_helm" "$tmp/c_foreign" "$tmp/c_none" "$tmp/ts"

    # `exec -a helm` makes the pty's owning process report as `helm` to `ps`, which is the
    # whole of what push.sh asks. Copying script(1) to a file named `helm` is the obvious
    # alternative and does not work — the copy loses its Apple signature and macOS answers
    # `Killed: 9` (measured).
    detach bash -c 'exec -a helm script -q /dev/null bash "$0" "$1"' "$tmp/run" "$tmp/c_helm"
    # A real pty, no helm anywhere above it: the Ghostty teammate of #282.
    detach script -q "$tmp/ts" bash "$tmp/run" "$tmp/c_foreign"
    # No pty anywhere in the chain: CI, or a daemon.
    detach bash "$tmp/run" "$tmp/c_none"

    # THE CONTROL AGAINST OVERSHOOT. A fix that simply refuses more passes the two negative
    # cases below and fails this one. It needs no running helm — only a pty whose owner
    # answers to the name — so it holds in CI too.
    check "a pty helm owns is delivered to"          0 "$(await_code "$tmp/c_helm")"

    # THE NEGATIVE CONTROL, and the whole of #282: a terminal that is not helm's.
    check "a pty helm does not own is refused"       8 "$(await_code "$tmp/c_foreign")"

    # Refusing has to be silent on the wire, not merely nonzero — the damage in #282 was an
    # escape sequence written into a terminal that never asked for one. Counting ESC bytes
    # rather than grepping for the marker keeps this honest if the marker is ever renamed.
    check "and emits no escape sequence into it"     0 \
        "$(LC_ALL=C tr -dc '\033' <"$tmp/ts" 2>/dev/null | wc -c | tr -d ' ')"

    # Distinct from the case above, because the operator's next move differs.
    check "no pty at all is a different refusal"     6 "$(await_code "$tmp/c_none")"
else
    printf '  skip  no script(1) — cannot stage a pty here\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
