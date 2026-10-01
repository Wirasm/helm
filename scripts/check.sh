#!/usr/bin/env bash
# The gate, defined once (#418). `just check` runs it; CI runs one part per job, so the two
# cannot drift apart the way AGENTS.md's one-liner and gate.yml's steps did.
#
#   scripts/check.sh                   every part: lint and skills always; swift,
#                                      daemon and pi when their paths changed (see `needs`).
#                                      Ends with a summary.
#   scripts/check.sh <part>...         only those parts, whatever changed
#   scripts/check.sh --needs <part> [base]
#                                      exit 0 if <part> must run for `base...HEAD`
#                                      (default base origin/development), 1 if not. CI uses it.
#
# Parts: lint swift skills daemon pi. Within a part the first failure stops it; across
# parts the run continues, so one red part does not hide another.
#
# HELM_CHECK_HEADLESS=1 is the one difference in the commands CI runs: no runner has an active
# display, and TerminalKeyboardTests and WorkbenchFocusRoutingTests need a real ghostty
# surface (#253), so they are skipped there. Nowhere else spells that skip.
#
# HELM_CHECK_MIN_FREE_GB (default 20) is the free space the run needs on the volume holding the
# repo; below it the gate refuses to start. A gate builds 3-4 GB of Swift and Rust per worktree,
# and sixty worktrees' builds filled the disk on 2026-10-01. CI sets it to 0, which turns it off.
#
# lint and swift need only the Swift toolchain and xcodegen (AGENTS.md). The other parts need
# node, bash/zsh/python3, cargo or npm; a missing tool is a FAIL that names it, never a skip.
set -uo pipefail
cd "$(dirname "$0")/.."

ALL_PARTS="lint swift skills daemon pi"

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
        lint | skills) return 0 ;;
    esac
    paths=$(changed_paths "$base") || {
        echo "check: cannot diff against $base; running $part" >&2
        return 0
    }
    case "$part" in
        # RenderableFile.swift: the bench CLI checks its extension list against it (bench open).
        # The shell-integration tree: benchd builds it in, for the shells terminal panes run.
        # GhosttyTerminal's Package.swift: daemon/test.sh checks the VT engine's commit against it.
        daemon) grep -qE '^(daemon/|\.github/workflows/daemon\.yml|\.claude/skills/bench-|\.claude/skills/helm-canvas/|\.claude/skills/helm-orchestrate/|Sources/Helm/Shared/RenderableFile\.swift|Sources/Helm/Resources/ghostty/shell-integration/|Packages/GhosttyTerminal/Package\.swift)' <<<"$paths" ;;
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
        daemon) echo "no changes under daemon/, daemon.yml, .claude/skills/bench-*, helm-canvas, helm-orchestrate, RenderableFile.swift or the shell integration" ;;
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
    echo "--> build"
    swift build --disable-keychain || return 1
    echo "--> test"
    # INJECTION_NOGENERICS=1 is not optional with --skip: anything that makes SwiftPM
    # enumerate goes through `swiftpm-xctest-helper`, which dies with `signalled(10)` when
    # InjectionNext rebinds symbols under it (docs/testing.md, "Running one suite").
    if [ "${HELM_CHECK_HEADLESS:-}" = 1 ]; then
        INJECTION_NOGENERICS=1 swift test --disable-keychain \
            --skip TerminalKeyboardTests --skip WorkbenchFocusRoutingTests || return 1
    else
        swift test --disable-keychain || return 1
    fi
    echo "--> xcodegen"
    xcodegen generate
}

part_skills() {
    for tool in node zsh python3 git; do require "$tool" skills || return 1; done
    bash .claude/skills/helm-board/test.sh || return 1
    bash .claude/skills/post-canvas/test.sh
}

part_daemon() {
    require cargo daemon || return 1
    bash daemon/test.sh
}

part_pi() {
    require node pi || return 1
    bash .claude/skills/pi-extensions/scripts/test.sh
}

# Run a part with TMPDIR pointed at a directory of its own, then hold it to leaving nothing
# there: a file left over is a test that does not clean up after itself, and a process with a
# file open there is one a test started and never stopped. Either fails the part, by name; the
# process is stopped (TERM, then KILL) and the directory removed either way, so a red run does not leave them too.
# The Rust suites, the skill gates and pi's all honour TMPDIR. The swift part runs without it:
# Foundation's temporary directory ignores TMPDIR, and SwiftPM keeps the locks that serialise
# builds sharing a .build there, so a private one would let two builds collide.
#
# Under /tmp, not $TMPDIR: the conformance suite binds sockets inside it, and a unix socket path
# caps near 104 bytes.
#
# Node keeps its compile cache under TMPDIR by default, so any node a part runs would leave
# node-compile-cache behind. A gate never wants that cache, so it is switched off rather than
# allowed through the leak check.
check_tmp=""
trap '[ -z "$check_tmp" ] || rm -rf "$check_tmp"' EXIT

run_contained() {
    local part=$1 status left holders
    require lsof "$part" || return 1
    check_tmp=$(mktemp -d /tmp/helm-check.XXXXXX) || return 1
    TMPDIR="$check_tmp/" NODE_DISABLE_COMPILE_CACHE=1 "part_$part"
    status=$?
    holders=$(lsof -nP -t +D "$check_tmp" 2>/dev/null | sort -u)
    if [ -n "$holders" ]; then
        echo "check: $part left processes running with files in its temp dir; stopping them:"
        ps -o pid=,command= -p "$(paste -sd, - <<<"$holders")"
        kill $holders 2>/dev/null
        sleep 1
        kill -9 $holders 2>/dev/null
        status=1
    fi
    left=$(cd "$check_tmp" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||')
    if [ -n "$left" ]; then
        echo "check: $part left files in its temp dir (a test that does not clean up):"
        sed 's/^/  /' <<<"$left"
        status=1
    fi
    rm -rf "$check_tmp"
    check_tmp=""
    return "$status"
}

run_part() { "part_$1"; }

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

# Refuses before any part builds. `df -Pk` is POSIX: the fourth column is free KiB.
min_free_gb=${HELM_CHECK_MIN_FREE_GB:-20}
case "$min_free_gb" in
    '' | *[!0-9]*) echo "check: HELM_CHECK_MIN_FREE_GB is '$min_free_gb'; it takes whole GB (0 turns the check off)" >&2; exit 2 ;;
esac
if [ "$min_free_gb" -gt 0 ]; then
    free_gb=$(( $(df -Pk . | awk 'NR == 2 { print $4 }') / 1024 / 1024 ))
    if [ "$free_gb" -lt "$min_free_gb" ]; then
        echo "check: only ${free_gb} GB free on the volume holding $(pwd); the gate needs ${min_free_gb} GB." >&2
        echo "  Every worktree keeps its own .build and daemon/target (3-4 GB). Free space with:" >&2
        echo "    just prune-worktrees --dry-run   # which merged worktrees would go" >&2
        echo "    just prune-worktrees" >&2
        echo "  HELM_CHECK_MIN_FREE_GB=<n> sets the floor; 0 turns this check off." >&2
        exit 2
    fi
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
    case "$part" in
        daemon | skills | pi) run=run_contained ;;
        *) run=run_part ;;
    esac
    if "$run" "$part"; then
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
