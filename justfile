# `just check` is the gate. The other recipes are operational, run against a live machine.
# Building stays in the Makefile.

set positional-arguments

default:
    @just --list

# The whole gate, or only the named parts (lint swift hooks skills daemon pi). Same as
# `bash scripts/check.sh`, which is the form that needs no `just`; CI runs the same parts.
check *parts:
    @bash scripts/check.sh "$@"

# Detaches and returns at once; the log path is printed, and ~/.helm/build/release-resume.log
# points at the newest. Options: scripts/release-resume.sh --help.
#
# Swap in the latest helm, restart benchd, resume <session-id> in the new helm with Remote Control
release-resume session-id *args:
    @bash scripts/release-resume.sh "$@"
