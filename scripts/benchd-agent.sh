#!/usr/bin/env bash
# benchd as a user LaunchAgent (#407): it starts at login and launchd restarts it after a crash.
#
#   scripts/benchd-agent.sh install [--no-build]     (or: just benchd-install)
#   scripts/benchd-agent.sh uninstall                (or: just benchd-uninstall)
#
# install builds bench and benchd into cargo's bin (as release-resume does), writes
# ~/Library/LaunchAgents/com.wirasm.benchd.plist, stops a hand-started benchd if one answers,
# loads the agent, and starts the shared browser once. After that benchd brings the browser back
# by itself: it stays wanted until `bench browser stop` (daemon/direction.md).
#
# KeepAlive restarts benchd on a crash or a kill, not on a clean exit, so `bench stop` still
# stops it until the next login or `launchctl kickstart`. Output goes to ~/Library/Logs/benchd.log.
#
# Only the live instance is installed. A suite (BENCH_SUITE) is run by hand; `just launchd-proof`
# in daemon/ bootstraps one from a temporary plist and boots it out again.
#
# Sourcing this file defines the functions and runs nothing; BenchdAgentScriptTests does that.

set -uo pipefail

agent_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# The launchd label: com.wirasm.benchd for the live root, com.wirasm.benchd.<suite> for a suite.
# release-resume derives the same label to decide whether to restart through launchctl.
agent_label() { printf 'com.wirasm.benchd%s\n' "${1:+.$1}"; }

agent_loaded() { timeout 10 launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }

# The binaries the agent runs and release-resume refreshes, installed from daemon/crates.
agent_crates=(bench benchd)

# write_plist <path> <label> <benchd> <log> [suite]
#
# PATH is the installer's own: benchd spawns claude, codex and pi by name, and launchd's default
# PATH (/usr/bin:/bin:/usr/sbin:/sbin) finds none of them.
write_plist() {
  local path="$1" label="$2" benchd="$3" logfile="$4" suite="${5:-}"
  rm -f "$path"
  plutil -create xml1 "$path" &&
    plutil -insert Label -string "$label" "$path" &&
    plutil -insert ProgramArguments -array "$path" &&
    plutil -insert ProgramArguments.0 -string "$benchd" "$path" &&
    plutil -insert RunAtLoad -bool YES "$path" &&
    plutil -insert KeepAlive -dictionary "$path" &&
    plutil -insert KeepAlive.SuccessfulExit -bool NO "$path" &&
    plutil -insert ProcessType -string Interactive "$path" &&
    plutil -insert StandardOutPath -string "$logfile" "$path" &&
    plutil -insert StandardErrorPath -string "$logfile" "$path" &&
    plutil -insert EnvironmentVariables -dictionary "$path" &&
    plutil -insert EnvironmentVariables.PATH -string "$PATH" "$path" || return 1
  if [ -n "$suite" ]; then
    plutil -insert EnvironmentVariables.BENCH_SUITE -string "$suite" "$path" || return 1
  fi
  plutil -lint -s "$path"
}

# Wait up to $2 seconds for `bench status` to answer (or, with "down", to stop answering).
await_bench() {
  local bench="$1" seconds="$2" want="${3:-up}" deadline
  deadline=$(($(date +%s) + seconds))
  while :; do
    if timeout 5 "$bench" status >/dev/null 2>&1; then
      [ "$want" = up ] && return 0
    else
      [ "$want" = down ] && return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

bench_pid() { timeout 5 "$1" status 2>/dev/null | plutil -extract pid raw - 2>/dev/null; }

agent_install() {
  local build=1
  case "${1:-}" in
  --no-build) build=0 ;;
  "") ;;
  *) echo "benchd-agent: unknown option $1" >&2; return 1 ;;
  esac
  # The agent is for the live root. Installed under either of these it would still boot the live
  # root (the plist carries neither), which is not what anyone setting them meant.
  if [ -n "${BENCH_SUITE+x}" ] || [ -n "${BENCH_DIR+x}" ]; then
    echo "benchd-agent: refusing to install with BENCH_SUITE or BENCH_DIR set — only the live benchd runs as a login agent; run a suite by hand" >&2
    return 3
  fi

  local bin="${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin" crate
  if [ "$build" -eq 1 ]; then
    for crate in "${agent_crates[@]}"; do
      echo "benchd-agent: cargo install $crate"
      timeout 1200 cargo install --locked --force --quiet --path "$agent_repo/daemon/crates/$crate" \
        --target-dir "$agent_repo/daemon/target" || { echo "benchd-agent: cargo install $crate failed" >&2; return 4; }
    done
  fi
  [ -x "$bin/benchd" ] && [ -x "$bin/bench" ] ||
    { echo "benchd-agent: no bench/benchd in $bin — run without --no-build" >&2; return 4; }

  local label plist logfile domain
  label="$(agent_label)"
  domain="gui/$(id -u)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  logfile="$HOME/Library/Logs/benchd.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$logfile")"
  write_plist "$plist" "$label" "$bin/benchd" "$logfile" ||
    { echo "benchd-agent: could not write $plist" >&2; return 4; }

  if agent_loaded "$label"; then
    echo "benchd-agent: reloading $label"
    timeout 30 launchctl bootout "$domain/$label" 2>/dev/null
    await_bench "$bin/bench" 20 down || { echo "benchd-agent: the old agent's benchd did not stop" >&2; return 4; }
  fi
  # Anything still answering was started by hand. One daemon per root: it goes, and launchd's
  # benchd replaces it.
  if timeout 5 "$bin/bench" status >/dev/null 2>&1; then
    echo "benchd-agent: stopping the hand-started benchd (pid $(bench_pid "$bin/bench"))"
    timeout 20 "$bin/bench" stop >/dev/null
    await_bench "$bin/bench" 20 down || { echo "benchd-agent: the running benchd did not stop; nothing loaded" >&2; return 4; }
  fi

  timeout 30 launchctl bootstrap "$domain" "$plist" || { echo "benchd-agent: launchctl bootstrap failed" >&2; return 4; }
  await_bench "$bin/bench" 20 || { echo "benchd-agent: benchd did not come up; see $logfile" >&2; return 4; }
  echo "benchd-agent: $label loaded, benchd pid $(bench_pid "$bin/bench"), log $logfile"

  # Marks the browser wanted, so every later benchd brings it back without being asked.
  timeout 90 "$bin/bench" browser start >/dev/null ||
    { echo "benchd-agent: benchd is up but bench browser start failed" >&2; return 4; }
  echo "benchd-agent: shared browser running; it comes back with benchd until \`bench browser stop\`"
}

agent_uninstall() {
  local label plist
  label="$(agent_label)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if agent_loaded "$label"; then
    timeout 30 launchctl bootout "gui/$(id -u)/$label" || return 4
  fi
  rm -f "$plist"
  echo "benchd-agent: $label removed; benchd no longer starts at login"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
  install) shift; agent_install "$@" ;;
  uninstall) agent_uninstall ;;
  *) echo "usage: benchd-agent.sh install [--no-build] | uninstall" >&2; exit 1 ;;
  esac
fi
