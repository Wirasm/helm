#!/usr/bin/env bash
# Put an artifact on the operator's helm bench.
#
# Exists because the obvious thing does not work. helm's push is an OSC 777 escape
# sequence, and an escape sequence only means anything if it reaches the pty helm is
# parsing — but an agent's tool call has its stdout CAPTURED by the harness and no
# controlling terminal at all. Measured from a Claude Code Bash tool call: tty '??',
# session 0, `/dev/tty` unopenable, `[ -t 1 ]` false. So a bare `printf` is read back to
# the agent as text and the operator sees nothing, with no error anywhere (#184).
#
# It works from a shell the operator typed into, which is exactly how it was tested and
# why it shipped wrong. Twice, counting the ⌘-click it replaced (#124, #166).
#
# So: resolve a pty we can actually write to, refuse loudly when there is none, and check
# the path before emitting rather than letting helm refuse it after.
#
# Usage:  push.sh /absolute/path/to/artifact.md
#
# Exit codes — a nonzero exit is the point, and each says what to do about it:
#   0  delivered
#   2  wrong number of arguments
#   3  path is not absolute
#   4  no such file
#   5  helm has no renderer for that extension
#   6  no reachable terminal — nothing was emitted

set -uo pipefail

readonly MARKER="helm.canvas"

die() {
    printf 'push.sh: %s\n' "$2" >&2
    exit "$1"
}

[ $# -eq 1 ] || die 2 "usage: push.sh /absolute/path/to/artifact.{md,html}"

artifact=$1

case "$artifact" in
    /*) ;;
    *) die 3 "path must be absolute — helm cannot know which directory you meant: $artifact" ;;
esac

[ -f "$artifact" ] || die 4 "no such file: $artifact"

# Take the extension off the BASENAME, not the path: `${artifact##*.}` on a dotless name
# like /etc/hosts falls through and returns the whole path, which then lands in the
# refusal message and reads like nonsense.
base=${artifact##*/}
case "$base" in
    *.*) ext=${base##*.} ;;
    *) ext="" ;;
esac
case "$ext" in
    md | markdown | mdown | html | htm) ;;
    *) die 5 "helm renders .md .markdown .mdown .html .htm — not: ${ext:-(no extension)}" ;;
esac

# Where can we actually write bytes the terminal will parse?
#
# Order matters. If stdout is already a terminal we are being run from a real shell and
# must not go hunting — that is the operator's own invocation and it already works.
# Otherwise walk up the process tree: the harness's shell is detached, but the agent
# process one or more hops up still owns the pty helm gave it.
resolve_sink() {
    if [ -t 1 ]; then
        printf '/dev/stdout\n'
        return 0
    fi

    local pid parent tty
    pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$tty" in
            ttys* | tty*[0-9])
                if [ -w "/dev/$tty" ]; then
                    printf '/dev/%s\n' "$tty"
                    return 0
                fi
                ;;
        esac
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ "$parent" = "$pid" ] && break
        pid=$parent
    done
    return 1
}

if ! sink=$(resolve_sink); then
    die 6 "no writable terminal in this process tree — nothing was emitted. \
You are probably not running inside a helm terminal; open the artifact with ⌘O instead, \
or hand the operator this path: $artifact"
fi

# OSC 777 — the only sequence ghostty both parses from OUTPUT and lets carry arbitrary
# text. Title is the discriminator, body the payload; ghostty splits on the first two
# semicolons only, so a path containing ';' survives intact.
#
# In a terminal that is NOT helm this degrades to an ordinary desktop notification rather
# than doing nothing, which is the right failure: the operator still sees the path.
printf '\033]777;notify;%s;%s\033\\' "$MARKER" "$artifact" >"$sink"

# The path as text, on the agent's own stdout, so it is in the transcript the operator
# reads even when the pane is not where they are looking — and so #168's copy affordance
# is not the only way to get it.
printf '%s\n' "$artifact"
