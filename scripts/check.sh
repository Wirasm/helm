#!/usr/bin/env bash
# The gate, defined once (#418). `just check` runs it; CI runs one part per job, so the two
# cannot drift apart the way AGENTS.md's one-liner and gate.yml's steps did.
#
#   scripts/check.sh                   every part: lint, hooks and skills always; swift,
#                                      daemon and pi when their paths changed (see `needs`).
#                                      Ends with a summary.
#   scripts/check.sh <part>...         only those parts, whatever changed
#   scripts/check.sh --needs <part> [base]
#                                      exit 0 if <part> must run for `base...HEAD`
#                                      (default base origin/development), 1 if not. CI uses it.
#
# Parts: lint swift hooks skills daemon pi. Within a part the first failure stops it; across
# parts the run continues, so one red part does not hide another.
#
# HELM_CHECK_HEADLESS=1 is the one difference in the commands CI runs: no runner has an active
# display, and TerminalKeyboardTests and WorkbenchFocusRoutingTests need a real ghostty
# surface (#253), so they are skipped there. Nowhere else spells that skip.
#
# lint and swift need only the Swift toolchain and xcodegen (AGENTS.md). The other parts need
# node, bash/zsh/python3, cargo or npm; a missing tool is a FAIL that names it, never a skip.
set -uo pipefail
cd "$(dirname "$0")/.."

ALL_PARTS="lint swift hooks skills daemon pi"

# ---- path rules: the only place that says which change needs which part ----

# Committed changes since the merge base, plus anything staged, unstaged or untracked, so a
# local run before committing sees the same parts CI will. In CI the tree is clean and only
# the first term matters.
changed_paths() {
    git diff --name-only "$1...HEAD" &&
        git diff --name-only HEAD &&
        git ls-files --others --exclude-standard
}

# needs <part> <base>: 0 = must run, 1 = nothing it covers changed.
needs() {
    local part=$1 base=$2 paths
    case "$part" in
        lint | hooks | skills) return 0 ;;
    esac
    paths=$(changed_paths "$base") || {
        echo "check: cannot diff against $base; running $part" >&2
        return 0
    }
    case "$part" in
        daemon) grep -qE '^(daemon/|\.github/workflows/daemon\.yml|\.claude/skills/bench-)' <<<"$paths" ;;
        pi) grep -qE '^pi/' <<<"$paths" ;;
        swift)
            # Runs when nothing changed at all, too: an empty diff proves nothing.
            [ -n "$paths" ] || return 0
            local path
            while IFS= read -r path; do
                swift_ignores "$path" || return 0
            done <<<"$paths"
            return 1
            ;;
        *) echo "check: unknown part '$part'" >&2; return 2 ;;
    esac
}


# A path no Swift build or test reads. Deliberately short, and anything not listed runs the
# swift part: tests read project.yml, scripts/, daemon/fixtures/ and the canvas and board
# skills, and Sources/ bundles markdown as resources. Re-grep Tests/ and Sources/ for repo
# paths before adding to it. CI's Swift job also skips its lint step on this answer, which is
# safe only while everything lint reads (Sources/, Tests/, tools/, .swiftlint.yml,
# .swift-format) stays outside this list.
swift_ignores() {
    case "$1" in
        daemon/fixtures/*) return 1 ;;
        docs/* | pi/* | daemon/* | .claude/agents/* | .github/workflows/daemon.yml) return 0 ;;
        Sources/* | Tests/* | .claude/skills/*) return 1 ;;
        *.md) return 0 ;;
        *) return 1 ;;
    esac
}

skip_reason() {
    case "$1" in
        swift) echo "only docs/, pi/, daemon/ (not fixtures) or markdown outside Sources/, Tests/ and skills changed" ;;
        daemon) echo "no changes under daemon/, daemon.yml or .claude/skills/bench-*" ;;
        pi) echo "no changes under pi/" ;;
    esac
}

# ---- parts ----

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "check: '$1' is not installed; the $2 part needs it"
        return 1
    }
}

part_lint() {
    make lint
}

part_swift() {
    require xcodegen swift || return 1
    echo "--> patch libghostty"
    bash scripts/patch-libghostty.sh || return 1
    echo "--> build"
    swift build --disable-keychain || return 1
    echo "--> test"
    # INJECTION_NOGENERICS=1 is not optional with --skip: anything that makes SwiftPM
    # enumerate goes through `swiftpm-xctest-helper`, which dies with `signalled(10)` when
    # InjectionNext rebinds symbols under it (AGENTS.md, the `--filter` paragraph).
    if [ "${HELM_CHECK_HEADLESS:-}" = 1 ]; then
        INJECTION_NOGENERICS=1 swift test --disable-keychain \
            --skip TerminalKeyboardTests --skip WorkbenchFocusRoutingTests || return 1
    else
        swift test --disable-keychain || return 1
    fi
    echo "--> xcodegen"
    xcodegen generate
}

part_hooks() {
    require node hooks || return 1
    bash hooks/test.sh
}

part_skills() {
    for tool in node zsh python3; do require "$tool" skills || return 1; done
    bash .claude/skills/helm-mail-cc/test.sh || return 1
    bash .claude/skills/helm-canvas/test.sh || return 1
    bash .claude/skills/helm-board/test.sh
}

part_daemon() {
    require cargo daemon || return 1
    bash daemon/test.sh
}

part_pi() {
    require node pi || return 1
    bash .claude/skills/pi-extensions/scripts/test.sh
}

rerun_command() {
    case "$1" in
        lint) echo "make lint" ;;
        *) echo "bash scripts/check.sh $1" ;;
    esac
}

# ---- entry ----

if [ "${1:-}" = "--needs" ]; then
    [ -n "${2:-}" ] || { echo "usage: scripts/check.sh --needs <part> [base]" >&2; exit 2; }
    needs "$2" "${3:-origin/development}"
    exit $?
fi

for part in "$@"; do
    case " $ALL_PARTS " in
        *" $part "*) ;;
        *) echo "check: unknown part '$part' (parts: $ALL_PARTS)" >&2; exit 2 ;;
    esac
done

explicit=$#
parts=${*:-$ALL_PARTS}
summary=()
failed=0
for part in $parts; do
    if [ "$explicit" -eq 0 ] && ! needs "$part" origin/development; then
        summary+=("$part SKIP ($(skip_reason "$part"))")
        continue
    fi
    echo "==> $part"
    if "part_$part"; then
        summary+=("$part PASS")
    else
        summary+=("$part FAIL (rerun: $(rerun_command "$part"))")
        failed=1
    fi
done

echo
echo "check summary:"
printf '  %s\n' "${summary[@]}"
exit "$failed"
