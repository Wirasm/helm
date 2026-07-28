#!/usr/bin/env bash
# Swift formatting and lint gate.
#
# `swift format` ships with the Swift 6 toolchain, so this needs no install and no
# dependency — which is why it was chosen over SwiftLint. The config in `.swift-format`
# describes the style the codebase ALREADY had rather than imposing a new one: matching
# indentation to 4 spaces and the line length to 100 took the finding count from 9,796 to
# 275. A formatter that wants to rewrite every file gets turned off within a week.
#
#   scripts/check-format.sh          lint only, non-zero exit on any finding (CI/gate)
#   scripts/check-format.sh --fix    rewrite in place
set -euo pipefail
cd "$(dirname "$0")/.."

# `tools/` is included deliberately. Those scripts are in no SwiftPM target, so
# `swift build` never sees them — they could rot for months and no gate would say so.
# kild hit the identical shape today: its tsconfig EXCLUDED the test files, so the code
# whose job is noticing drift was the one thing nothing checked.
TARGETS="Sources Tests tools"

if [ "${1:-}" = "--fix" ]; then
    swift format --in-place --recursive $TARGETS
    echo "formatted."
    exit 0
fi

# Typecheck the standalone tools too. Formatting proves they parse; only the compiler
# proves they still build against the SDK they call into.
for script in tools/*.swift; do
    [ -e "$script" ] || continue
    if ! swiftc -typecheck "$script" >/dev/null 2>&1; then
        echo "typecheck FAILED: $script"
        swiftc -typecheck "$script" 2>&1 | head -5
        exit 1
    fi
done

findings=$(swift format lint --recursive $TARGETS 2>&1 || true)
if [ -n "$findings" ]; then
    echo "$findings"
    echo
    echo "$(printf '%s\n' "$findings" | wc -l | tr -d ' ') finding(s). Run: scripts/check-format.sh --fix"
    exit 1
fi
echo "format: clean"
