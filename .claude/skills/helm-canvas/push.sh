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
# So: resolve a pty we can actually write to, refuse loudly when there is none, check the
# path before emitting rather than letting helm refuse it after — and never report success
# for a write that did not happen, which is the whole guarantee this script sells.
#
# Usage:  push.sh /absolute/path/to/artifact.md
#
# Exit codes — a nonzero exit is the point, and each says what to do about it:
#   0  delivered
#   2  wrong number of arguments
#   3  path is not absolute
#   4  no such file
#   5  helm has no renderer for that extension
#   6  no reachable terminal, or the write to it failed — nothing was emitted
#   7  path contains control characters

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

# A path is bytes, and only NUL and `/` are forbidden in one — so a filename may legally
# contain ESC. Splicing that into an OSC string hands the terminal a second, unrelated
# sequence: the parser ends the OSC at the embedded ESC and then executes whatever follows
# as its own command (`ESC ] 0 ; … BEL` retitles the window; OSC 52 writes the clipboard).
# ghostty's "splits on the first two semicolons" only describes what happens AFTER a
# well-formed sequence is parsed, so it is no defence here at all. Refuse rather than strip:
# a mangled path that half-works is worse than a clear no.
if printf '%s' "$artifact" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die 7 "path contains control characters, refusing to emit it into a terminal"
fi

[ -f "$artifact" ] || die 4 "no such file: $artifact"

# Take the extension off the BASENAME, not the path: `${artifact##*.}` on a dotless name
# like /etc/hosts falls through and returns the whole path, which then lands in the
# refusal message and reads like nonsense.
base=${artifact##*/}
case "$base" in
    *.*) ext=${base##*.} ;;
    *) ext="" ;;
esac
# Mirrors `RenderableFile.isRenderable` in Sources/Helm/Shared/RenderableFile.swift, which
# is what helm itself checks. Keep the two lists in step by hand — the same convention
# AGENTS.md documents for hooks/helm-mail.mjs and its pi twin. Drift here can only refuse
# something helm would have rendered, never the reverse, which is why the duplicate is
# worth having: the alternative is emitting and learning about it from a banner.
case "$ext" in
    md | markdown | mdown | html | htm) ;;
    *) die 5 "helm renders .md .markdown .mdown .html .htm — not: ${ext:-(no extension)}" ;;
esac

# Where can we actually write bytes the terminal will parse?
#
# Walk up the process tree: the harness's shell is detached, but the agent process one or
# more hops up still owns the pty helm gave it. Ancestors only, bounded at pid 1, and every
# candidate still has to pass a real writability check — so this cannot wander into an
# unrelated session's terminal.
resolve_sink() {
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

# `[ -t 1 ]` has to be asked HERE, in the main body. Inside `$(...)` fd 1 is the pipe bash
# uses to capture the output, never the caller's stdout — so the same test inside
# resolve_sink is unconditionally false and the branch would be dead code wearing a
# comment that claims otherwise.
if [ -t 1 ]; then
    # The operator's own invocation from a real shell. That path was never broken; do not
    # go hunting for a terminal when we are already sitting in one.
    sink=/dev/stdout
elif ! sink=$(resolve_sink); then
    die 6 "no writable terminal in this process tree — nothing was emitted. \
You are probably not running inside a helm terminal; open the artifact with ⌘O instead, \
or hand the operator this path: $artifact"
fi

# OSC 777 — the only sequence ghostty both parses from OUTPUT and lets carry arbitrary
# text. Title is the discriminator, body the payload.
#
# In a terminal that is NOT helm this degrades to an ordinary desktop notification rather
# than doing nothing, which is the right failure: the operator still sees the path.
#
# The status IS checked. `-w` proved a permission bit at check time, not that an open and
# write will succeed now — the reading end can be gone, and the whole point of this script
# is that "nothing happened" must never be reported as success.
if ! printf '\033]777;notify;%s;%s\033\\' "$MARKER" "$artifact" >"$sink"; then
    die 6 "resolved $sink but the write failed — nothing was emitted: $artifact"
fi

# The path as text, on the agent's own stdout, so it is in the transcript the operator
# reads even when the pane is not where they are looking — and so #168's copy affordance
# is not the only way to get it.
printf '%s\n' "$artifact"
