#!/usr/bin/env bash
# Gate for the board skill. Needs bash, node and shasum — deliberately NOT part of the Swift
# gate, on the same rule the mail and canvas gates follow: `swift test` cannot run JavaScript
# and should not learn how, and a Swift contributor should never need a JS toolchain to go green.
#
#   bash .claude/skills/helm-board/test.sh
#
# Three things it checks, and one it deliberately leaves to the Swift gate.
#
#   - `board-core.js`, EXECUTED — every decision the board makes, run in node against real
#     record shapes. That file exists so this is possible: a browser-only glue file is testable
#     by looking at it, which is the medium helm #197 measured three consecutive silent defects
#     in.
#   - `new-board.sh` refuses what it should, with the code it documents, and stages what it says.
#   - The vendored `@quickdrawjs/core` still hashes to what `quickdraw/VENDORED.txt` pinned. A
#     vendored dependency whose bytes nobody checks is a CDN with extra steps.
#
# **`data-helm-surface` is NOT checked here.** It is a seam between this template, helm's
# annotation script and a Swift constant, and it is gated once — in
# `CanvasSurfaceTests.testEveryHalfOfTheSurfaceSeamStillSpellsItTheSameWay`, which reads all
# three halves and runs on every `swift test`. A second copy of that assertion here would be a
# second thing to keep in step, which is the defect the seam rule exists to remove.
#
# What NO gate can prove: that a real trackpad stroke reaches quickdraw. Run a board in a live
# helm and draw on it.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
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

ok() {
    local label=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n' "$label"
    fi
}

command -v node >/dev/null 2>&1 || {
    printf 'node is required for this gate\n' >&2
    exit 1
}

# --- board-core.js, executed ------------------------------------------------------------------
# Copied to `.mjs` so node reads the shipped bytes as the ES module a browser does. The
# alternative is a `package.json` in this directory that exists only for the test runner, and a
# file that ships for no other reason is a file that drifts.
cp "$here/board-core.js" "$tmp/board-core.mjs"
printf 'board-core.js\n'
if BOARD_CORE="$tmp/board-core.mjs" node "$here/board-core.test.mjs"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf '  FAIL  board-core.test.mjs\n'
fi

# --- board.js parses as a module ---------------------------------------------------------------
printf '\nboard.js\n'
cp "$here/board.js" "$tmp/board.mjs"
ok "parses as an ES module" node --check "$tmp/board.mjs"
ok "imports quickdraw as a sibling, never from a CDN" \
    grep -q 'from "\./quickdraw/index\.js"' "$here/board.js"
ok "and nothing in the skill reaches the network" \
    bash -c "! grep -RInE 'https?://' '$here/board.js' '$here/board-core.js' '$here/board.html'"

# --- new-board.sh ------------------------------------------------------------------------------
printf '\nnew-board.sh\n'
new="$here/new-board.sh"

run_code() {
    bash "$new" "$@" >/dev/null 2>&1
    printf '%s' $?
}

check "no arguments" 2 "$(run_code)"
check "an option it does not know" 2 "$(run_code --wat /tmp/a.html)"
check "two artifact paths" 2 "$(run_code /a.html /b.html)"
check "a relative path" 3 "$(run_code board.html)"
check "a directory that is not there" 4 "$(run_code /nonexistent/dir/board.html)"
check "an extension helm has no renderer for" 5 "$(run_code "$tmp/board.md")"

evil=$(printf '%s/evil\033]0;PWNED\007.html' "$tmp")
check "a path carrying control bytes" 7 "$(run_code "$evil")"

# --- it stages what it says --------------------------------------------------------------------
board="$tmp/plan-board.html"
check "a clean run" 0 "$(run_code "$board" --title 'The plan')"
ok "the artifact is there" test -f "$board"
ok "the document is there" test -f "$tmp/plan-board.document.json"
ok "the library is there" test -f "$tmp/quickdraw/index.js"
ok "the glue is there" test -f "$tmp/board.js"
ok "the glue's core is there" test -f "$tmp/board-core.js"
ok "the title was substituted" grep -q 'The plan' "$board"
ok "and no placeholder survived" bash -c "! grep -q '__TITLE__' '$board'"
ok "the empty document parses" node -e "JSON.parse(require('fs').readFileSync('$tmp/plan-board.document.json','utf8'))"

check "a second run refuses rather than clobbering" 6 "$(run_code "$board")"

# The document is the AGENT's work and --force must never take it. Anything else here is
# helm's and is replaced.
printf '{"document":{"store":{"keep":{"id":"keep","typeName":"shape","type":"geo","x":0,"y":0,"rot":0,"z":1,"props":{"geo":"rectangle","w":10,"h":10,"label":"Keep"}}}}}\n' \
    >"$tmp/plan-board.document.json"
check "--force rewrites the artifact" 0 "$(run_code "$board" --force)"
ok "and leaves the agent's document alone" grep -q '"keep"' "$tmp/plan-board.document.json"

# A title is text, not syntax. `&` is the trap: it means "the matched text" in both sed's and
# awk's replacement, and this script got it wrong until this case said so — `A/B & C` came out
# as `A/B __TITLE__ C`.
check "a title with substitution metacharacters" 0 "$(run_code "$tmp/odd.html" --title 'A/B & C')"
ok "survives, escaped as the markup it lands in" grep -q 'A/B &amp; C' "$tmp/odd.html"
ok "and no placeholder is left behind by the scan" bash -c "! grep -q '__TITLE__' '$tmp/odd.html'"

# The title reaches `<title>` and `<h1>` as markup, and the caller is not always the person
# reading the board.
check "a title that would be markup" 0 "$(run_code "$tmp/sharp.html" --title '<script>boom()</script>')"
ok "is escaped rather than executed" bash -c "! grep -q '<script>boom' '$tmp/sharp.html'"
ok "and is still legible" grep -q '&lt;script&gt;boom' "$tmp/sharp.html"

# --- the vendored bytes ------------------------------------------------------------------------
printf '\nvendored @quickdrawjs/core\n'
if command -v shasum >/dev/null 2>&1; then
    (
        cd "$here" || exit 1
        # VENDORED.txt carries a prose header before the hash lines; feed shasum only the lines
        # that are one.
        grep -E '^[0-9a-f]{64}  ' quickdraw/VENDORED.txt >"$tmp/pins"
        shasum -a 256 -c "$tmp/pins"
    ) >"$tmp/hashes" 2>&1
    verified=$?
    # Spelled out rather than run through `ok`, and the reason is the whole point of the
    # diagnostic: `ok` ends in a `printf`, so it returns 0 whichever branch it took and
    # `ok … || cat` could never fire. The failure was still reported — but on a real pin
    # mismatch the one line that says WHICH file changed was dropped, which is a gate telling
    # you something is wrong and refusing to say what.
    if [ "$verified" -eq 0 ]; then
        pass=$((pass + 1))
        printf '  ok    every file still hashes to its pin\n'
    else
        fail=$((fail + 1))
        printf '  FAIL  every file still hashes to its pin\n'
        sed 's/^/        /' "$tmp/hashes"
    fi
    check "and every shipped file is pinned" \
        "$(ls "$here"/quickdraw/*.js "$here"/quickdraw/*.css | wc -l | tr -d ' ')" \
        "$(grep -cE '^[0-9a-f]{64}  ' "$here/quickdraw/VENDORED.txt")"
else
    printf '  skip  no shasum(1)\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
