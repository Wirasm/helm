#!/usr/bin/env bash
# The operator's day as one markdown page (#422): agent sessions per workspace, PRs merged and
# opened, unread operator mail, and open issues asking for a decision. Plain data, no
# summarising; an agent can read the same file.
#
#   scripts/day.sh [--no-push] [since]      (or: just day …)
#
# `since` is a date, YYYY-MM-DD; the default is yesterday. The page goes to the prp store of
# this repo, <store>/digests/<today>.md, and is then pushed to the bench with the helm-canvas
# skill's push.sh, unless --no-push. Outside a helm pane push.sh refuses and the path is
# printed instead.
#
# A source that fails says so on the page. An empty section means the source answered with
# nothing; `_unavailable: …_` means it did not answer. BENCH and GH name the binaries.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BENCH="${BENCH:-bench}"
GH="${GH:-gh}"

push=1
if [ "${1:-}" = "--no-push" ]; then push=0; shift; fi
since="${1:-$(date -v-1d +%Y-%m-%d)}"
if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "day: since must be a date, YYYY-MM-DD (got \"$since\")" >&2
    exit 2
fi
# The round trip refuses a date that is shaped right and does not exist (2026-13-01).
since_s="$(date -j -f %Y-%m-%d-%H%M%S "$since-000000" +%s 2>/dev/null)"
if [ -z "$since_s" ] || [ "$(date -j -r "$since_s" +%Y-%m-%d)" != "$since" ]; then
    echo "day: $since is not a date" >&2
    exit 2
fi
since_ms=$(( since_s * 1000 ))
today="$(date +%Y-%m-%d)"

# The prp skills' canonical store resolver, rooted at this script's repo rather than $PWD, so
# `just day` finds helm's store from any directory.
_gd="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
case "$_gd" in */.git) _root="${_gd%/.git}" ;; "") _root="$repo" ;; *) _root="$_gd" ;; esac
_root="$(cd "$_root" && pwd -P)"
_name="$(basename "$_root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
_home="${PRP_HOME:-$HOME/.prp}"
_hit="$(grep -lsF "\"path\": \"$_root\"" "$_home"/*/project.json 2>/dev/null | head -1)"
PRP_DIR="${_hit%/project.json}"
[ -n "$PRP_DIR" ] || PRP_DIR="$_home/${_name:-project}-$(printf %s "$_root" | git hash-object --stdin | cut -c1-8)"
mkdir -p "$PRP_DIR"; [ -f "$PRP_DIR/project.json" ] || printf '{"path": "%s", "name": "%s"}\n' "$_root" "${_name:-project}" > "$PRP_DIR/project.json"

out_dir="$PRP_DIR/digests"
mkdir -p "$out_dir"
page="$out_dir/$today.md"

err="$(mktemp "${TMPDIR:-/tmp}/day-err.XXXXXX")"
trap 'rm -f "$err"' EXIT

# Runs a command bounded to 30 s. Its stdout is the answer; on failure it prints the
# unavailable line for the page and returns 1.
ask() {
    local answer
    if answer="$(timeout 30 "$@" 2>"$err")"; then
        printf '%s' "$answer"
    else
        local why
        why="$(grep -m1 . "$err" | sed 's/^bench: //')"
        printf '_unavailable: `%s` failed%s_\n' "$*" "${why:+: $why}"
        return 1
    fi
}

# Renders a source's JSON answer with jq. An answer jq cannot read is reported like a
# failed command, never rendered as an empty section. Usage: render <label> <json> <jq args…>
render() {
    local label="$1" json="$2" out
    shift 2
    if out="$(printf '%s' "$json" | jq -r "$@" 2>"$err")"; then
        printf '%s\n' "$out"
    else
        printf '_unavailable: the answer of `%s` is not what this script reads (%s)_\n' \
            "$label" "$(grep -m1 . "$err")"
    fi
}

# The operator's workspaces are the ones helm has open; without helm's snapshot, this repo.
# A snapshot that exists and cannot be read is said on the page.
snapshot="${HELM_BENCH_DIR:-$HOME/.helm/bench}/snapshot.json"
workspaces=()
snapshot_note=""
if [ -f "$snapshot" ]; then
    if listed="$(jq -er '.workspaces[].path' "$snapshot" 2>"$err")"; then
        while IFS= read -r w; do workspaces+=("$w"); done <<<"$listed"
    else
        snapshot_note="_$snapshot could not be read ($(grep -m1 . "$err")), so only this repo is listed._"
    fi
fi
[ ${#workspaces[@]} -gt 0 ] || workspaces=("$_root")

sessions() {
    local ws="$1" json
    printf '\n### %s\n\n' "$ws"
    json="$(ask "$BENCH" sessions --all --workspace "$ws")" || { printf '%s\n' "$json"; return; }
    render "$BENCH sessions --all" "$json" --argjson since "$since_ms" '
      def when(ms): (ms / 1000 | strflocaltime("%a %H:%M"));
      [.rows[] | select(.state.kind == "running" or .state.at_ms >= $since)] as $rows
      | if ($rows | length) == 0 then "Nothing running or finished since then."
        else $rows[] | "- "
          + (if .state.kind == "running" then "running · " + .state.activity.kind
             else "finished " + when(.state.at_ms) end)
          + " — " + .harness + " · " + (.name // "(unnamed)")
          + " · " + .host.kind + " · `" + .id + "`"
        end,
        (.unreadable // [] | .[] | "- _unreadable " + .source + ": " + .why + "_")'
}

# Workspaces that are GitHub repos, once each, as owner/name. A gh that cannot answer at all
# is reported once, not taken to mean that no workspace is on GitHub.
repos=()
gh_down=""
answer="$(ask "$GH" auth status)" || gh_down="$answer"
[ -n "$gh_down" ] || for ws in "${workspaces[@]}"; do
    r="$(cd "$ws" 2>/dev/null && timeout 30 "$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || continue
    [ -n "$r" ] || continue
    case " ${repos[*]-} " in *" $r "*) ;; *) repos+=("$r") ;; esac
done

# gh stops at --limit without saying so. Asking for one more than is shown tells the page
# whether anything was cut.
LIMIT=100

prs() {
    local repo="$1" state="$2" query="$3" json
    json="$(ask "$GH" pr list --repo "$repo" --state "$state" --search "$query" \
        --limit $((LIMIT + 1)) --json number,title,url,author,isDraft)" || { printf '%s\n' "$json"; return; }
    render "$GH pr list" "$json" --argjson limit "$LIMIT" '
      if length == 0 then "- none" else .[:$limit][] | "- [#\(.number)](\(.url)) \(.title) — \(.author.login)"
        + (if .isDraft then " · draft" else "" end) end,
      (if length > $limit then "- _the first \($limit) only_" else empty end)'
}

decisions() {
    local repo="$1" json
    json="$(ask "$GH" issue list --repo "$repo" --state open --search '"Decision needed"' \
        --limit $((LIMIT + 1)) --json number,title,url)" || { printf '%s\n' "$json"; return; }
    render "$GH issue list" "$json" --argjson limit "$LIMIT" '
      if length == 0 then "- none" else .[:$limit][] | "- [#\(.number)](\(.url)) \(.title)" end,
      (if length > $limit then "- _the first \($limit) only_" else empty end)'
}

mail() {
    local json
    json="$(ask "$BENCH" mail list --handle operator)" || { printf '%s\n' "$json"; return; }
    render "$BENCH mail list" "$json" '
      [.mail[] | select(.unread)] as $m
      | if ($m | length) == 0 then "No unread mail."
        else $m[] | "- \(.at) from **\(.from)**: \(.subject // "(no subject)") · `\(.id)`" end,
        (if .truncated then "- _\(.total - .returned) more not listed_" else empty end)'
}

{
    printf '# The day, %s\n\n' "$today"
    printf 'Since %s. Written %s by `just day`.\n' "$since" "$(date '+%H:%M')"

    printf '\n## Agent sessions\n'
    [ -z "$snapshot_note" ] || printf '\n%s\n' "$snapshot_note"
    for ws in "${workspaces[@]}"; do sessions "$ws"; done
    printf '\n`bench log <id>` shows what a session did.\n'

    printf '\n## Pull requests\n'
    if [ -n "$gh_down" ]; then
        printf '\n%s\n' "$gh_down"
    elif [ ${#repos[@]} -eq 0 ]; then
        printf '\nNo workspace is a GitHub repository.\n'
    fi
    # ${a[@]+…}: bash 3.2 calls an empty array unbound under set -u.
    for r in ${repos[@]+"${repos[@]}"}; do
        printf '\n### %s\n\n**Merged**\n\n' "$r"
        prs "$r" merged "merged:>=$since"
        printf '\n**Opened, still open**\n\n'
        prs "$r" open "created:>=$since"
    done

    printf '\n## Unread mail for operator\n\n'
    mail

    printf '\n## Open decisions\n\nOpen issues that say "Decision needed".\n'
    [ -z "$gh_down" ] || printf '\n%s\n' "$gh_down"
    for r in ${repos[@]+"${repos[@]}"}; do
        printf '\n### %s\n\n' "$r"
        decisions "$r"
    done
} > "$page"

echo "day: wrote $page"
[ "$push" = 1 ] || exit 0
if "$repo/.claude/skills/helm-canvas/push.sh" "$page"; then
    echo "day: on the bench"
else
    echo "day: not pushed to the bench (push.sh exit $?); open $page"
fi
