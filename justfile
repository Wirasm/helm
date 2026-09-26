# `just check` is the gate. The other recipes are operational, run against a live machine.
# Building stays in the Makefile.

set positional-arguments

default:
    @just --list

# The whole gate, or only the named parts (lint swift skills daemon pi). Same as
# `bash scripts/check.sh`, which is the form that needs no `just`; CI runs the same parts.
check *parts:
    @bash scripts/check.sh "$@"

# Detaches and returns at once; the log path is printed, and ~/.helm/build/release-resume.log
# points at the newest. Options: scripts/release-resume.sh --help.
#
# Swap in the latest helm, restart benchd, resume <session-id> in the new helm with Remote Control
release-resume session-id *args:
    @bash scripts/release-resume.sh "$@"

# The day on one page: agent sessions per workspace, PRs merged and opened, unread operator mail,
# open decisions. Written to the prp store and pushed to the bench when run in a helm pane.
# Options: [--no-push] [since YYYY-MM-DD, default yesterday]; scripts/day.sh has the details.
day *args:
    @bash scripts/day.sh "$@"

# benchd as a login agent (com.wirasm.benchd): builds bench and benchd, loads the agent, replaces
# a hand-started benchd, and starts the shared browser. launchd restarts benchd after a crash, and
# benchd brings the browser back until `bench browser stop`. Only the live instance, never a suite.
benchd-install *args:
    @bash scripts/benchd-agent.sh install "$@"

# Unload the benchd login agent and delete its plist. benchd stops with it.
benchd-uninstall:
    @bash scripts/benchd-agent.sh uninstall
