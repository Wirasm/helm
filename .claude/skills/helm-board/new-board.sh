#!/usr/bin/env bash
# Stage a drawable board beside an artifact path.
#
#   new-board.sh /absolute/path/to/plan-board.html [--title "Plan"] [--force]
#
# Copies the vendored `@quickdrawjs/core`, `board.js` and `board-core.js` next to the artifact,
# writes the artifact itself from `board.html`, and creates an empty `<name>.document.json` for
# the agent's own shapes. Then edit that JSON and `push.sh` the `.html`.
#
# **Every refusal has its own exit code**, on push.sh's rule — a caller has to be able to act on
# one, and "it printed something" is not a result:
#   2  wrong number of arguments / an option this does not know
#   3  the path is not absolute
#   4  the parent directory does not exist
#   5  the path does not end in .html or .htm
#   6  the artifact already exists and --force was not given
#   7  the path contains control characters
#   8  a copy failed
#
# Re-running with --force rewrites the artifact and refreshes the library; it NEVER touches
# `<name>.document.json`, because that file is the agent's own work.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
    printf '%s\n' "$2" >&2
    exit "$1"
}

target=""
title=""
force=0

while [ $# -gt 0 ]; do
    case "$1" in
        --title)
            [ $# -ge 2 ] || die 2 "--title needs a value"
            title=$2
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        -*)
            die 2 "unknown option: $1"
            ;;
        *)
            [ -z "$target" ] || die 2 "expected one artifact path, got a second: $1"
            target=$1
            shift
            ;;
    esac
done

[ -n "$target" ] || die 2 "usage: new-board.sh /absolute/path/to/board.html [--title T] [--force]"

case "$target" in
    /*) ;;
    *) die 3 "the path must be absolute, and ~ is not expanded by every caller: $target" ;;
esac

# The same guard push.sh carries, for the same reason: only NUL and / are illegal in a Unix
# path, so a filename can carry an ESC — and this one is echoed back to the operator.
printf '%s' "$target" | LC_ALL=C grep -q '[[:cntrl:]]' &&
    die 7 "the path contains control characters"

case "$target" in
    *.html | *.htm) ;;
    *) die 5 "helm renders .html and .htm as pages; this is not one: $target" ;;
esac

dir=$(dirname "$target")
[ -d "$dir" ] || die 4 "no such directory: $dir"

if [ -e "$target" ] && [ "$force" -eq 0 ]; then
    die 6 "$target already exists — pass --force to rewrite it (the document JSON is untouched)"
fi

name=$(basename "$target")
stem=${name%.*}
[ -n "$title" ] || title=$stem

# --- the library, and helm's glue -------------------------------------------------------------
rm -rf "$dir/quickdraw" || die 8 "could not replace $dir/quickdraw"
cp -R "$here/quickdraw" "$dir/quickdraw" || die 8 "could not copy quickdraw to $dir"
cp "$here/board.js" "$here/board-core.js" "$dir/" || die 8 "could not copy the board glue to $dir"

# --- the artifact ------------------------------------------------------------------------------
# The title lands in markup, so it is escaped as markup first. `&` before the angle brackets, or
# `&lt;` would come back out as `&amp;lt;`.
escaped=$title
escaped=${escaped//&/&amp;}
escaped=${escaped//</&lt;}
escaped=${escaped//>/&gt;}

# Substituted by scanning, not by `gsub` and not by `sed` — **both treat `&` in the replacement
# as "the text that matched"**, so `--title 'A/B & C'` came out as `A/B __TITLE__ C`. That was a
# real failure of this script caught by its own gate, and it is why the replacement below reads
# left to right and never re-scans what it has already written.
awk -v title="$escaped" '
    {
        out = ""; rest = $0
        while ((at = index(rest, "__TITLE__")) > 0) {
            out = out substr(rest, 1, at - 1) title
            rest = substr(rest, at + 9)
        }
        print out rest
    }
' "$here/board.html" >"$target" || die 8 "could not write $target"

# --- the agent's document, if it is not there already -------------------------------------------
document="$dir/$stem.document.json"
if [ ! -e "$document" ]; then
    printf '{\n  "document": {\n    "store": {}\n  }\n}\n' >"$document" ||
        die 8 "could not write $document"
fi

printf 'board    %s\n' "$target"
printf 'document %s\n' "$document"
printf 'library  %s/quickdraw (@quickdrawjs/core 0.2.0, vendored)\n' "$dir"
printf '\nWrite your shapes into the document, then push the board:\n'
printf '  ~/.claude/skills/helm-canvas/push.sh %s\n' "$target"
