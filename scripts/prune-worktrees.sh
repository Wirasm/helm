#!/usr/bin/env bash
# Remove the worktrees under .worktrees/ whose work has landed, and their builds with them.
# Each worktree carries its own .build and daemon/target (1-6 GB together), so fifty merged
# worktrees filled the disk to 3.3 GB free on 2026-09-28.
#
#   scripts/prune-worktrees.sh             remove every one that qualifies
#   scripts/prune-worktrees.sh --dry-run   say which would go, remove nothing
#   scripts/prune-worktrees.sh --branch <b> [--branch <b>...]
#                                          consider only the worktrees on those branches: the
#                                          merge queue's cleanup after a batch it merged
#
# A worktree goes only when all of these hold, and a line names the first that does not:
#   - its HEAD reached origin/development through a merge: an ancestor of it, and not on its
#     first-parent line. A worktree just made from development is on that line, so a fresh one
#     with nothing committed yet is never taken for merged work.
#   - no tracked file is modified or staged.
#   - it is not locked (`git worktree lock`).
#   - no process has its working directory inside it: an agent or a build is still there.
# `git worktree remove` itself refuses one holding untracked files that are not ignored, so new
# work nobody committed stays too. Branches are left alone.
set -uo pipefail
cd "$(dirname "$0")/.."

dry_run=0
branches=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --branch)
            [ -n "${2:-}" ] || { echo "prune: --branch needs a name" >&2; exit 2; }
            branches+=("refs/heads/$2")
            shift
            ;;
        *) echo "usage: scripts/prune-worktrees.sh [--dry-run] [--branch <name>]..." >&2; exit 2 ;;
    esac
    shift
done

timeout 60 git fetch --quiet origin development || { echo "prune: cannot fetch origin" >&2; exit 1; }
base=$(git rev-parse origin/development) || exit 1
first_parent=$(git rev-list --first-parent "$base")
# The main checkout is the first entry, spelled the way git spells every other one.
root="$(git worktree list --porcelain | sed -n '1s/^worktree //p')/.worktrees/"
busy=$(timeout 30 lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | grep -F "$root" || true)

removed=0 kept=0
path="" head="" branch="" locked=0
# Named branches only, when any were named. A detached worktree (the queue's own, a review
# checkout) is on no branch, so it is never one of them.
named() {
    [ ${#branches[@]} -eq 0 ] && return 0
    local b
    for b in "${branches[@]}"; do [ "$b" = "$branch" ] && return 0; done
    return 1
}
consider() {
    [[ -n "$path" && "$path" == "$root"* ]] || return 0
    named || return 0
    local why=""
    if [ "$locked" = 1 ]; then
        why="locked"
    elif [ -z "$head" ] || ! git merge-base --is-ancestor "$head" "$base"; then
        why="not merged"
    elif grep -qx "$head" <<<"$first_parent"; then
        why="nothing of its own merged yet"
    elif [ -n "$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        why="tracked changes"
    elif grep -qxF "$path" <<<"$busy" || grep -qF "$path/" <<<"$busy"; then
        why="a process is working in it"
    fi
    if [ -n "$why" ]; then
        echo "keep   ${path#"$root"} ($why)"
        kept=$((kept + 1))
    elif [ "$dry_run" = 1 ]; then
        echo "would remove ${path#"$root"}"
        removed=$((removed + 1))
    elif timeout 300 git worktree remove "$path"; then
        echo "remove ${path#"$root"}"
        removed=$((removed + 1))
    else
        echo "keep   ${path#"$root"} (git worktree remove refused)"
        kept=$((kept + 1))
    fi
}

while IFS= read -r line; do
    case "$line" in
        "worktree "*) path="${line#worktree }" head="" branch="" locked=0 ;;
        "HEAD "*) head="${line#HEAD }" ;;
        "branch "*) branch="${line#branch }" ;;
        locked*) locked=1 ;;
        "") consider; path="" ;;
    esac
done < <(git worktree list --porcelain; echo)

if [ "$dry_run" = 1 ]; then
    echo "prune: $removed would go, $kept stay"
else
    git worktree prune
    echo "prune: $removed removed, $kept kept"
fi
