#!/usr/bin/env bash
# Size and complexity gate (#418): the limits in `.swiftlint.yml`, as errors.
#
# SwiftLint comes from the pinned package in `tools/lint/`, so this needs only the Swift
# toolchain, plus network the first time SwiftPM fetches the binary (about 25s, cached in
# tools/lint/.build after that). `--disable-keychain` is not optional: without it SwiftPM
# can block for minutes on a github.com keychain lookup before downloading anything.
#
# SwiftLint prints file:line:col and the measured number but not the declaration's name,
# so each finding is followed by the source line it points at. For every rule except
# file_length (which points at the file's last line) that line is the declaration itself,
# including superfluous_disable_command, which points at the declaration its marker guards.
#
#   scripts/check-size.sh      non-zero exit on any finding (part of `make lint`)
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

status=0
output=$(swift package --package-path tools/lint --disable-keychain \
    lint --config .swiftlint.yml --no-cache --quiet 2>&1) || status=$?

findings=0
while IFS= read -r line; do
    case "$line" in
        "$root"/*:*:*": error: "*)
            finding="${line#"$root"/}"
            echo "$finding"
            file="${finding%%:*}"
            rest="${finding#*:}"
            lineno="${rest%%:*}"
            if [[ "$finding" != *"(file_length)" ]]; then
                echo "    $(sed -n "${lineno}p" "$file" | sed 's/^[[:space:]]*//')"
            fi
            findings=$((findings + 1))
            ;;
        # The plugin's own restatement of SwiftLint's exit status.
        "error: Plugin ended with exit code"*) ;;
        "") ;;
        *) echo "$line" ;;
    esac
done < <(printf '%s\n' "$output" | sort)

if [ "$findings" -gt 0 ]; then
    echo
    echo "$findings size/complexity finding(s). Split the function or type until it is under the"
    echo "limit; never add a swiftlint:disable marker to new code. superfluous_disable_command"
    echo "means a legacy site is now under its limit: delete its marker. Limits: .swiftlint.yml"
    exit 1
fi
if [ "$status" -ne 0 ]; then
    echo "size: swiftlint exited $status without reporting a finding (output above)."
    exit "$status"
fi
echo "size: clean"
