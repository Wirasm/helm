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
msg=$("$push" "$tmp/artifact.zip" 2>&1 >/dev/null)
case "$msg" in
    *zip*) pass=$((pass + 1)); printf '  ok    refusal names the offending extension\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  refusal did not name the extension: %s\n' "$msg" ;;
esac

msg=$("$push" "$tmp/noext" 2>&1 >/dev/null)
case "$msg" in
    *"no extension"*) pass=$((pass + 1)); printf '  ok    a dotless path is described as such\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  dotless path refusal reads wrong: %s\n' "$msg" ;;
esac

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
case "$out" in
    *"$tmp/probe.md"*) pass=$((pass + 1)); printf '  ok    the path is printed for the operator\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  path not printed: %s\n' "$out" ;;
esac
case "$code" in
    0) pass=$((pass + 1)); printf '  ok    delivered with stdout captured (the #184 case)\n' ;;
    6) pass=$((pass + 1)); printf '  ok    refused loudly — no pty here, nothing emitted\n' ;;
    *) fail=$((fail + 1)); printf '  FAIL  unexpected exit %s with stdout captured\n' "$code" ;;
esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
