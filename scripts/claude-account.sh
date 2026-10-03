#!/usr/bin/env bash
# A second Claude login that differs from the default only in its login.
#
#   scripts/claude-account.sh add <dir>    make <dir> a second login and list it for benchd
#   scripts/claude-account.sh seed <dir>   bring <dir> up to date with the default config again
#
# Claude keeps one login per config dir (CLAUDE_CONFIG_DIR), and keys the login's keychain item by
# that dir's path. `add` makes <dir> a set of links into ~/.claude for everything except what
# belongs to one login, so an agent there runs the operator's own settings, hooks, skills,
# plugins and CLAUDE.md, and writes its transcripts and live-session files where benchd reads
# them. Never linked, and never copied: the login (.credentials.json, the keychain), .claude.json
# and its backups, the background daemon and its jobs, MCP sign-in state, and an organisation's
# managed policy.
#
# .claude.json cannot be a link: it holds the login's identity (oauthAccount) beside things that
# are the machine's, which a fresh one lacks, so an agent there would stop at the theme picker and
# then at the folder trust dialog, unattended. `add` and `seed` merge those in from
# ~/.claude.json: onboarding, the documented /config keys, user MCP servers, and per-folder trust
# and approvals. Nothing else, and oauthAccount never.
#
# `add` also lists <dir> in benchd's accounts.toml (BENCH_DIR, else ~/.bench-$BENCH_SUITE, else
# ~/.bench). benchd starts agents on it once it is logged in (Claude writes the account into its
# .claude.json at /login), so listing it before the login is harmless. Both commands are safe to
# run again.
# `seed` is the one to run after trusting a new top-level folder or adding an MCP server in the
# default login, and it reports an entry that stopped being a link (Claude can replace a linked
# file with its own copy). It refuses while a claude runs on <dir>, which rewrites .claude.json
# from memory and would undo the merge. Logging <dir> in is the operator's, once, by hand.
set -euo pipefail

usage() {
    echo "usage: scripts/claude-account.sh add|seed <dir>" >&2
    exit 2
}
[ $# -eq 2 ] || usage
command=$1
case "$command" in add | seed) ;; *) usage ;; esac

base="$HOME/.claude"
base_json="$HOME/.claude.json"
# Absolute and without a trailing slash: the spelling benchd will set, and so the keychain item
# the operator's login lands in.
dir=${2/#\~/$HOME}
case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
dir=${dir%/}
[ "$dir" != "$base" ] || { echo "claude-account: $dir is the default login" >&2; exit 2; }
# It is written into accounts.toml and into a command line for the operator to paste.
case "$dir" in *[[:space:]\\\"\']*)
    echo "claude-account: pick a dir without spaces, quotes or backslashes: $dir" >&2
    exit 2
    ;;
esac
[ -d "$base" ] || { echo "claude-account: no $base to link to" >&2; exit 1; }

if [ -n "${BENCH_DIR:-}" ]; then
    root=$BENCH_DIR
elif [ -n "${BENCH_SUITE:-}" ]; then
    root="$HOME/.bench-$BENCH_SUITE"
else
    root="$HOME/.bench"
fi

# A claude on <dir>: `ps -E` appends each of the operator's own processes' environment to its
# command, space-separated, so the variable is followed by a space or ends the line.
running=$(ps -AEww -o pid=,command= 2>/dev/null | awk -v want="CLAUDE_CONFIG_DIR=$dir" '
    function is_claude(path) { return path ~ /(^|\/)claude$/ }
    (is_claude($2) || is_claude($3)) &&
        (index($0, want " ") > 0 || substr($0, length($0) - length(want) + 1) == want) { print $1 }
' || true)
if [ -n "$running" ]; then
    echo "claude-account: a claude is running on $dir; quit it first:" >&2
    echo "$running" | sed 's/^/  pid /' >&2
    exit 1
fi

# The two benchd reads must be links, so they exist in the default before anything is linked:
# one Claude would otherwise make in <dir> on its first run would be its own, and benchd refuses
# a login whose projects or sessions are not the default's.
mkdir -p "$base/projects" "$base/sessions" "$dir"
problems=0
for path in "$base"/* "$base"/.[!.]*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=$(basename "$path")
    case "$name" in
        .claude.json | .claude.json.* | .credentials.json | backups | daemon | daemon.log | \
            daemon-auth-* | jobs | mcp-needs-auth-cache.json | policy-limits.json | \
            remote-settings.json | .DS_Store) continue ;;
    esac
    link="$dir/$name"
    if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$path" ] && continue
        echo "claude-account: $link links to $(readlink "$link"), not $path" >&2
        problems=$((problems + 1))
    elif [ -e "$link" ]; then
        echo "claude-account: $link is its own copy, not a link to $path; move what you need out of it, delete it, and run seed again" >&2
        problems=$((problems + 1))
    else
        ln -s "$path" "$link"
    fi
done

seeded="no $base_json to seed from"
[ ! -e "$base_json" ] || seeded=".claude.json seeded from $base_json"
[ ! -e "$base_json" ] || python3 - "$base_json" "$dir/.claude.json" <<'PY'
import json, os, sys
base = json.load(open(sys.argv[1]))
path = sys.argv[2]
mine = json.load(open(path)) if os.path.exists(path) else {}
TOP = ["hasCompletedOnboarding", "lastOnboardingVersion", "theme", "mcpServers",
       "autoConnectIde", "autoInstallIdeExtension", "claudeInChromeDefaultEnabled",
       "copyFullResponse", "copyOnSelect", "defaultToAgentsView", "diffTool",
       "externalEditorContext", "leftArrowOpensAgents", "prStatusFooterEnabled",
       "autoCompactEnabled", "editorMode"]
PROJECT = ["hasTrustDialogAccepted", "allowedTools", "mcpServers", "enabledMcpjsonServers",
           "disabledMcpjsonServers", "hasClaudeMdExternalIncludesApproved",
           "hasClaudeMdExternalIncludesWarningShown", "ignorePatterns"]
for key in TOP:
    if key in base:
        mine[key] = base[key]
projects = mine.setdefault("projects", {})
for folder, entry in base.get("projects", {}).items():
    keep = {k: entry[k] for k in PROJECT if k in entry}
    if keep:
        projects.setdefault(folder, {}).update(keep)
tmp = path + ".seed"
with open(tmp, "w") as f:
    json.dump(mine, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

if [ "$command" = add ]; then
    mkdir -p "$root"
    accounts="$root/accounts.toml"
    if ! grep -qxF "dir = \"$dir\"" "$accounts" 2>/dev/null; then
        printf '[[claude]]\ndir = "%s"\n' "$dir" >>"$accounts"
        echo "listed $dir in $accounts"
    fi
fi

echo "$dir: linked to $base, $seeded"
[ "$problems" -eq 0 ] || { echo "claude-account: $problems entries need you (above)" >&2; exit 1; }
if [ "$command" = add ]; then
    echo "benchd starts agents on it once it is logged in. Once, by hand:"
    echo "  CLAUDE_CONFIG_DIR=$dir claude    then /login with the second account, and /exit"
fi
