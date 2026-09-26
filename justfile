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

# The day on one page: agent sessions per workspace, PRs merged and opened, unread operator mail,
# open decisions. Written to the prp store and pushed to the bench when run in a helm pane.
# Options: [--no-push] [since YYYY-MM-DD, default yesterday]; scripts/day.sh has the details.
day *args:
    @bash scripts/day.sh "$@"
