# Operational recipes. Building stays in the Makefile; these are the things run against a live
# machine.

set positional-arguments

default:
    @just --list

# Detaches and returns at once; the log path is printed, and ~/.helm/build/release-resume.log
# points at the newest. Options: scripts/release-resume.sh --help.
#
# Swap in the latest helm, restart benchd, resume <session-id> in the new helm with Remote Control
release-resume session-id *args:
    @bash scripts/release-resume.sh "$@"

# benchd as a login agent (com.wirasm.benchd): builds bench and benchd, loads the agent, replaces
# a hand-started benchd, and starts the shared browser. launchd restarts benchd after a crash, and
# benchd brings the browser back until `bench browser stop`. Only the live instance, never a suite.
benchd-install *args:
    @bash scripts/benchd-agent.sh install "$@"

# Unload the benchd login agent and delete its plist. benchd stops with it.
benchd-uninstall:
    @bash scripts/benchd-agent.sh uninstall
