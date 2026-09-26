#!/usr/bin/env bash
# Gate for the post-canvas skill. Needs bash, zsh, git and node, so it is not part of the Swift
# gate, on the same rule as the canvas, board and mail gates.
#
#   bash .claude/skills/post-canvas/test.sh
#
# It builds archon-video stored runs in a temp ARCHON_HOME, shaped the way the pack's
# `make/scripts/store.py` writes them, and checks that the driver finds the right one, renders
# what the run stored and refuses what is not a stored run. Then it runs the SKILL.md snippet
# itself, so the documented resolver and the driver's `--store` flag cannot drift apart.
#
# **It never pushes.** Every run of the driver goes through `run`, which adds `--no-push`, and a
# check below fails if anything else in this file starts the driver. helm-canvas's gate learned
# that the hard way: a gate run from a helm pane put its test artifacts on the operator's bench.
#
# What no gate can prove: that the page looks right. Render one against a real stored video and
# look at it (SKILL.md, "Verify a render without helm").

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
driver="$here/build-canvas.mjs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

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

for tool in node git zsh; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s is required for this gate\n' "$tool" >&2
        exit 1
    }
done

# The one place the driver is started. stdout and stderr land in $tmp/out and $tmp/err; the
# exit code is printed. Runs from $cwd, with ARCHON_HOME pointed at the fixture.
cwd=$tmp
run() {
    (cd "$cwd" && ARCHON_HOME="$tmp/archon" node "$driver" "$@" --no-push >"$tmp/out" 2>"$tmp/err")
    printf '%s' $?
}

# store_video <state-dir> <run-id> <title>: one stored run, the files store.py writes.
store_video() {
    local d="$1/video/videos/$2"
    mkdir -p "$d/frames"
    printf 'mp4 %s' "$2" >"$d/video.mp4"
    printf 'sheet' >"$d/frames/review-2.jpg"
    printf 'sheet' >"$d/frames/review-10.jpg"
    printf 'frame' >"$d/frames/t000.50.jpg"
    cat >"$d/manifest.json" <<EOF
{"run_id": "$2", "created_at": "2026-09-26T10:00:00+00:00", "brief": "Why agents need gates",
 "format": "vertical", "playbook_version": 3, "voice": {"provider": "cartesia", "model": "sonic-3.5"},
 "duration": 31.2, "edit_summary": "Opens on the diff, closes on the merge.", "qc": {"passed": true, "flags": []}}
EOF
    cat >"$d/script.json" <<EOF
{"choice": 1, "changes": "none", "title": "$3", "narration": "Every agent needs a gate.",
 "overlay": "No gate, no merge", "first_frame": "A red merge button"}
EOF
    cat >"$d/copy.json" <<'EOF'
{"youtube_title": "Gates for agents", "youtube_description": "The hook line.\nSecond paragraph.\n\nagent gates",
 "youtube_tags": ["agents", "ci"], "tiktok_caption": "gates #agents", "instagram_caption": "Gates.",
 "hashtags": ["agents", "devtools"], "alt_text": "A merge button turning green."}
EOF
    cat >"$d/qc.json" <<'EOF'
{"global_ok": true, "global_failures": [], "flags": [{"t": 4.5, "issue": "silence of 0.7 s or more"}],
 "measurements": {"width": 1080, "height": 1920, "fps": 30.0, "duration": 31.2,
 "integrated_lufs": -14.1, "true_peak_dbtp": -1.4}, "frame_hashes": []}
EOF
}

store=$tmp/store
mkdir -p "$store"

# --- the store is required -------------------------------------------------------------------
printf 'the store\n'
check "no --store is refused" 1 "$(run latest)"
ok "and says how to get one" grep -q 'resolve it with the block in SKILL.md' "$tmp/err"
check "a relative --store is refused" 1 "$(run --store store latest)"
check "a --store that does not exist is refused" 1 "$(run --store "$tmp/nowhere" latest)"

# --- finding the library ---------------------------------------------------------------------
printf '\nfinding the library\n'
proj=$tmp/proj/archon-video
mkdir -p "$proj"
git -C "$proj" init -q
git -C "$proj" remote add origin git@github.com:Owner/archon-video.git
cwd=$proj

check "nothing stored anywhere" 1 "$(run --store "$store")"
ok "names every place it looked" bash -c "grep -q 'Owner/archon-video/state' '$tmp/err' \
    && grep -q '_local/archon-video/state' '$tmp/err' && grep -q '_cwd/archon-video/state' '$tmp/err'"

# A decoy under _cwd: the registered owner/repo workspace must win over it.
store_video "$tmp/archon/workspaces/_cwd/archon-video/state" decoy0000000 "Decoy"
ln -s decoy0000000 "$tmp/archon/workspaces/_cwd/archon-video/state/video/videos/latest"
repo_state=$tmp/archon/workspaces/Owner/archon-video/state
store_video "$repo_state" aaaa1111bbbb "Older <b>run</b>"
store_video "$repo_state" cccc2222dddd "Newer run"
ln -s aaaa1111bbbb "$repo_state/video/videos/latest"
# A failed store leaves a dot-prefixed staging dir. Make it the newest thing in the folder.
mkdir -p "$repo_state/video/videos/.eeee3333ffff.partial"
touch "$repo_state/video/videos/cccc2222dddd"

check "latest renders" 0 "$(run --store "$store")"
artifact=$(cat "$tmp/out")
check "into the store, named by run id" "$store/post-aaaa1111/canvas.html" "$artifact"
ok "the owner/repo workspace wins over _cwd" bash -c "! grep -q Decoy '$artifact'"
ok "latest follows the link, not the newest folder" grep -q 'Older &lt;b&gt;run&lt;/b&gt;' "$artifact"
ok "the video is copied beside the page" test -f "$store/post-aaaa1111/video.mp4"
ok "and is a copy, not a link" test ! -L "$store/post-aaaa1111/video.mp4"
ok "review sheets are copied" test -f "$store/post-aaaa1111/frames/review-10.jpg"
ok "loose frames are not" test ! -e "$store/post-aaaa1111/frames/t000.50.jpg"
ok "sheets are in numeric order" bash -c "grep -o 'review-[0-9]*' '$artifact' | tr '\n' ' ' | grep -q 'review-2 review-10'"

printf '\nrendering\n'
ok "the charset is declared" grep -q '<meta charset="utf-8">' "$artifact"
ok "YouTube folds after the first line" grep -q '<div class="yt-desc">The hook line.</div>' "$artifact"
ok "the overlay is the hook" grep -q 'No gate, no merge' "$artifact"
ok "the brief is shown" grep -q 'Why agents need gates' "$artifact"
ok "a QC flag is listed with its time" grep -q '4.5s' "$artifact"
ok "and counted on the pill" grep -q '1 FLAG<' "$artifact"
ok "nothing is fetched at runtime" bash -c "! grep -q 'fetch(' '$artifact'"

check "a run id renders that run" 0 "$(run --store "$store" cccc2222dddd)"
ok "the right one" grep -q 'Newer run' "$(cat "$tmp/out")"
check ".. is not a run" 1 "$(run --store "$store" ..)"
check "an unknown run id" 1 "$(run --store "$store" nope)"
ok "says what is missing" grep -q 'missing video.mp4' "$tmp/err"

check "a path renders that directory" 0 "$(run --store "$store" "$repo_state/video/videos/cccc2222dddd")"

rm "$repo_state/video/videos/cccc2222dddd/copy.json"
check "a run without copy.json is refused, not invented" 1 "$(run --store "$store" cccc2222dddd)"
ok "and says so" grep -q 'missing copy.json' "$tmp/err"

# Without a remote, Archon files an unregistered cwd under _cwd/<name>.
plain=$tmp/proj/plain-dir
mkdir -p "$plain"
store_video "$tmp/archon/workspaces/_cwd/plain-dir/state" 9999aaaa0000 "Plain"
ln -s 9999aaaa0000 "$tmp/archon/workspaces/_cwd/plain-dir/state/video/videos/latest"
cwd=$plain
check "_cwd is found without a remote" 0 "$(run --store "$store")"
ok "the right one" grep -q 'Plain' "$(cat "$tmp/out")"

cwd=$tmp
check "STATE_DIR skips the guess" 0 "$(STATE_DIR="$repo_state" run --store "$store")"
ok "the right one" grep -q 'Older' "$(cat "$tmp/out")"

# --- the SKILL.md snippet, executed ----------------------------------------------------------
# Extracted rather than retyped: a retyped snippet passes while the doc says something else.
# Run under zsh, the shell Claude Code's Bash tool runs.
printf '\nthe SKILL.md snippet\n'
awk '/^## Run it/{f=1} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$here/SKILL.md" >"$tmp/snippet.sh"
check "has exactly one driver line" 1 "$(grep -c 'post-canvas/build-canvas.mjs' "$tmp/snippet.sh")"
sed -i.bak "s#node ~/.claude/skills/post-canvas/build-canvas.mjs\(.*\)#node '$driver'\1 --no-push#" "$tmp/snippet.sh"
check "and the rewrite reached it" 1 "$(grep -c -- '--no-push' "$tmp/snippet.sh")"

cwd=$proj
snip() {
    (cd "$cwd" && PRP_HOME="$tmp/prp" ARCHON_HOME="$tmp/archon" zsh "$tmp/snippet.sh" >"$tmp/out" 2>"$tmp/err")
    printf '%s' $?
}
check "runs" 0 "$(snip)"
first=$(cat "$tmp/out")
ok "into a store under PRP_HOME" bash -c "case '$first' in '$tmp/prp/archon-video-'*/post-aaaa1111/canvas.html) ;; *) false ;; esac"
ok "which records this project" grep -qF "\"path\": \"$proj\"" "$tmp/prp/"*/project.json
check "a second run" 0 "$(snip)"
check "adopts the same store" "$first" "$(cat "$tmp/out")"

# --- the gate itself ---------------------------------------------------------------------------
printf '\nthis gate\n'
check "starts the driver from one line only" 1 "$(grep -c 'node "\$driver"' "$0")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
