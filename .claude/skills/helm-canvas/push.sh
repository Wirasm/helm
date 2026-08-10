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
# And a third time (#282), which is the reason for `pty_owner` below. Writable is not the
# same question as helm's: outside a pane the walk found a real tty, wrote a real escape
# sequence, and a terminal that has never heard of `helm.canvas` consumed it. Every layer
# succeeded and nothing was pushed — the same shape as #184, one step out. So the check is
# now about the PTY rather than about the process asking, and it has to be: `$HELM_PANE` is
# inherited by everything a pane's agent spawns, so inside `script(1)` started from a pane
# it still names the pane while the tty is script's (measured 2026-08-10 — the variable said
# yes about a terminal helm cannot see).
#
# So: resolve a pty helm is actually parsing, refuse loudly when there is none, check the
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
#   6  no terminal reachable at all, or the write failed — nothing was emitted
#   7  path contains control characters
#   8  a terminal is reachable but helm does not own it — nothing was emitted
#
# 6 and 8 are split because the operator's next move differs. 6 is headless: no tty anywhere
# in the process tree, so hand over the path. 8 is a Ghostty, Terminal, tmux or ssh shell —
# there IS somewhere to type, just not somewhere helm reads.

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

# The two walks below share these three. `ps` prints nothing for a pid it no longer knows
# about, and `tr -d ' '` turns that into an empty string rather than an error — which every
# caller already reads as "stop walking". `-o tty=` pads its column and `-o comm=` does not,
# which is why only these two are trimmed.
walkable() { [ -n "$1" ] && [ "$1" -gt 1 ] 2>/dev/null; }
ppid_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
tty_of() { ps -o tty= -p "$1" 2>/dev/null | tr -d ' '; }

# Who opened this pty?
#
# libghostty opens one pty per pane and spawns one `/usr/bin/login` on it, holding the
# master itself — so walking up from a process ON that tty until the tty CHANGES lands on
# whoever opened it. helm for a pane; Ghostty, Terminal, `script(1)` or a tmux server for
# anything else. Measured in a live pane: `login`(ttys005) → `Helm`(??).
#
# `$1` is a pid known to be on tty `$2`. Prints the owner's command basename.
pty_owner() {
    local pid=$1 tty=$2 parent parent_tty owner
    while walkable "$pid"; do
        parent=$(ppid_of "$pid")
        [ "$parent" = "$pid" ] && return 1
        walkable "$parent" || return 1
        parent_tty=$(tty_of "$parent")
        if [ "$parent_tty" != "$tty" ]; then
            # Untrimmed on purpose: an argv[0] may contain spaces, so a basename is the
            # whole of the cleanup.
            owner=$(ps -o comm= -p "$parent" 2>/dev/null)
            printf '%s\n' "${owner##*/}"
            return 0
        fi
        pid=$parent
    done
    return 1
}

# `/Applications/Helm.app/Contents/MacOS/Helm` from `make install`, `.build/debug/helm`
# from `swift run`. A second helm instance is deliberately good enough: if you are in the
# worktree build's pane, that is the helm you want the artifact in.
#
# This is a delivery check and not a security boundary — argv[0] is spoofable, and anything
# able to spoof it can already write to your pty directly. A false accept is only the old
# behaviour; a false refusal is loud and says what it refused.
is_helm() {
    case "$1" in
        helm | Helm) return 0 ;;
        *) return 1 ;;
    esac
}

# Where can we write bytes that helm will parse?
#
# Walk up the process tree: the harness's shell is detached, but the agent process one or
# more hops up still owns the pty helm gave it. Ancestors only, bounded at pid 1, and every
# candidate has to be writable AND helm's.
#
# A foreign terminal does not stop the walk, it is walked PAST — an agent working inside a
# nested pty inside a pane then still delivers to the pane's own pty, which is a real
# terminal helm really is parsing. Only when the walk ends with nothing helm owns is this a
# refusal, and it says which of the two refusals it is:
#
#   0  the helm pty, on stdout
#   2  no helm pty, but a terminal was reachable — its owner's name, on stdout
#   1  no terminal at all
resolve_sink() {
    local pid parent tty foreign="" owner
    pid=$$
    while walkable "$pid"; do
        tty=$(tty_of "$pid")
        case "$tty" in
            ttys* | tty*[0-9])
                if [ -w "/dev/$tty" ]; then
                    # Every failure path in pty_owner returns without printing, so this is
                    # empty on failure — and `is_helm ""` already refuses.
                    owner=$(pty_owner "$pid" "$tty")
                    if is_helm "$owner"; then
                        printf '/dev/%s\n' "$tty"
                        return 0
                    fi
                    [ -n "$foreign" ] || foreign=${owner:-unknown}
                fi
                ;;
        esac
        parent=$(ppid_of "$pid")
        [ "$parent" = "$pid" ] && break
        pid=$parent
    done
    if [ -n "$foreign" ]; then
        printf '%s\n' "$foreign"
        return 2
    fi
    return 1
}

# There is no `[ -t 1 ] → /dev/stdout` fast path any more, and its absence is the fix.
# `/dev/stdout` has no name to ask `ps` about, so ownership cannot be proved for it — and
# that branch is exactly where the operator's own Ghostty window landed, emitting into a
# terminal helm does not read and calling it delivery (#282). The walk starts at `$$`, whose
# tty IS the controlling terminal in the operator's own shell, so that case is covered by
# the one code path rather than by a second one that cannot be checked.
resolved=$(resolve_sink)
case $? in
    0) sink=$resolved ;;
    2)
        die 8 "the reachable terminal is owned by '$resolved', not by helm — nothing was \
emitted. The OSC only means anything to the pty helm is parsing, so a Ghostty, Terminal, tmux \
or ssh shell swallows it and nothing appears on the bench. Run this from a helm pane, or hand \
the operator this path: $artifact"
        ;;
    *)
        die 6 "no writable terminal in this process tree — nothing was emitted. \
Open the artifact with ⌘O instead, or hand the operator this path: $artifact"
        ;;
esac

# OSC 777 — the only sequence ghostty both parses from OUTPUT and lets carry arbitrary
# text. Title is the discriminator, body the payload.
#
# This used to say that a non-helm terminal degrades to an ordinary desktop notification,
# "which is the right failure: the operator still sees the path". It is not, and that
# sentence is what #282 overturned: a notification is not a canvas, the artifact is not on
# the bench, and the caller was told zero. Nothing but a helm pty gets here now.
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
