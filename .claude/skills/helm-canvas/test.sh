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
    # 0 when a terminal is reachable, 6 when this runs somewhere with no pty at all (CI).
    case "$code" in
        0 | 6) pass=$((pass + 1)); printf '  ok    .%s is renderable\n' "$ext" ;;
        *) fail=$((fail + 1)); printf '  FAIL  .%s rejected with %s\n' "$ext" "$code" ;;
    esac
done

# --- delivery, for real ------------------------------------------------------------------
# The case #184 is about: run from a context whose stdout is NOT a terminal, which is what
# an agent's tool call looks like. Piping to cat is exactly that.
printf '# probe\n' >"$tmp/probe.md"
out=$("$push" "$tmp/probe.md" 2>&1 | cat)
code=${PIPESTATUS[0]:-0}
check_contains "the path is printed for the operator" "$tmp/probe.md" "$out"
case "$code" in
    0) pass=$((pass + 1)); printf '  ok    delivered with stdout captured\n' ;;
    6) pass=$((pass + 1)); printf '  ok    refused loudly — no pty here, nothing emitted\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  unexpected exit %s with stdout captured\n' "$code" ;;
esac

# The case above accepts 0 OR 6, so it cannot fail a resolve_sink that never finds
# anything — which is precisely the regression this whole script exists to prevent. This
# one can: `script` guarantees a pty in the ancestor chain while the pipe keeps push.sh's
# own stdout off a terminal, which is the agent-tool-call shape. Exit 0 exactly.
if command -v script >/dev/null 2>&1; then
    # The exit code goes to a FILE, not to stdout. Under `script` the pty is captured too,
    # so the OSC push.sh just emitted lands in that stream — parsing a status out of it
    # means parsing around the very sequence under test.
    # `</dev/null` is load-bearing: script(1) tcgetattr's its own stdin, and nested inside an
    # agent's tool call that is a SOCKET — "Operation not supported on socket", no pty, no
    # code file. It ran fine by hand, which is the same trap this whole PR is about.
    rm -f "$tmp/code"
    script -q /dev/null bash -c \
        "'$push' '$tmp/probe.md' >/dev/null 2>&1 | cat; \
         printf '%s' \${PIPESTATUS[0]} > '$tmp/code'" >/dev/null 2>&1 </dev/null
    if [ -f "$tmp/code" ]; then
        check "pty discovery works when one IS reachable" 0 "$(cat "$tmp/code")"
    else
        # Could not stage a pty at all — say so rather than passing, which is how the
        # permissive version of this check hid a broken walk.
        printf '  skip  script(1) could not allocate a pty here\n'
    fi
else
    printf '  skip  no script(1) — cannot guarantee a pty ancestor here\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
