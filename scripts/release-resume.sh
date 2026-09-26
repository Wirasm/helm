#!/usr/bin/env bash
# Build the latest helm, swap it in, restart benchd, and resume one Claude Code session inside
# the new helm with Remote Control on (#404). For an operator who is away from the machine and
# driving the work from his phone through that session.
#
#   scripts/release-resume.sh <session-id> [cwd] [options]      (or: just release-resume …)
#
#   --bundle PATH          the helm bundle to replace            (default /Applications/Helm.app)
#   --pid PID              the helm to quit; must be running from --bundle
#                          (default: the one process running from --bundle)
#   --suite NAME           HELM_DEFAULTS_SUITE for the relaunch          (default: none)
#   --bench-suite NAME     BENCH_SUITE for the benchd restart     (default: --suite);
#                          a loaded login agent for it is restarted with launchctl kickstart
#   --cargo-root DIR       where bench and benchd are installed  (default: cargo's own, ~/.cargo)
#   --env KEY=VALUE        extra environment for the relaunched helm, repeatable
#   --no-remote-control    resume without --remote-control
#
# `cwd` is where the session runs, because `claude --resume` finds a session by project
# directory. Left out, it is read from the session's own row in ~/.claude/sessions.
#
# WHY IT DETACHES. Quitting helm closes every pane, and the caller is normally an agent in one of
# them. So this checks everything it can in the foreground, then re-runs itself in a new session
# (double fork, nohup, setsid) and returns. The detached run waits until its parent is init
# before it touches anything; a skill gate's detached runner is where that race was learned.
# Every step runs under `timeout`, so nothing outlives its deadline.
#
# WHAT IT NEVER LEAVES BEHIND. Once helm has been asked to quit, the session must come back
# somewhere. If any later step fails (the swap, the relaunch, the resume), the session
# is resumed outside helm instead: `claude --bg --resume <id> --remote-control`, reachable from the
# phone and with `claude attach`. The log says which of the two happened.
#
# The log is ~/.helm/build/release-resume-<stamp>/log (HELM_BUILD_DIR moves it), and
# ~/.helm/build/release-resume.log always points at the newest. Its last line starts `RESULT:`.
#
# Sourcing this file defines the functions and runs nothing; ReleaseResumeScriptTests does that.

set -uo pipefail

self="${BASH_SOURCE[0]}"
repo="$(cd "$(dirname "$self")/.." && pwd -P)"

# ---- small helpers ----------------------------------------------------------------------------

log() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
refuse() {
  echo "release-resume: $*" >&2
  exit 3
}

realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# agent_label, agent_loaded, bench_pid and agent_crates: how benchd is installed and run under
# launchd, spelled once.
# shellcheck source=benchd-agent.sh
source "$repo/scripts/benchd-agent.sh"

alive() { kill -0 "$1" 2>/dev/null; }

# The executable a bundle runs, with every symlink resolved — the form LaunchServices execs it
# by, so it compares equal to what `ps` reports.
bundle_executable() {
  local real name
  real="$(realdir "$1")" || return 1
  name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$real/Contents/Info.plist" 2>/dev/null)" || return 1
  printf '%s/Contents/MacOS/%s\n' "$real" "$name"
}

# A pid's executable, resolved the same way.
pid_executable() {
  local comm dir
  comm="$(ps -o comm= -p "$1" 2>/dev/null)" || return 1
  [[ "$comm" == /* ]] || return 1
  dir="$(realdir "${comm%/*}")" || return 1
  printf '%s/%s\n' "$dir" "${comm##*/}"
}

# Every pid running from the bundle. By executable path, never by bundle id: a worktree build
# shares the id with the installed app, and quitting by id can quit the operator's helm.
bundle_pids() {
  local exe pid comm
  exe="$(bundle_executable "$1")" || return 1
  ps -Ao pid=,comm= | while read -r pid comm; do
    [ "${comm##*/}" = "${exe##*/}" ] || continue
    [ "$(pid_executable "$pid")" = "$exe" ] && echo "$pid"
  done
}

# The helm to quit: the given pid, only if it runs from the bundle; otherwise the one process
# that does. Refuses rather than guesses, because the wrong answer quits somebody's helm.
resolve_helm_pid() {
  local bundle="$1" given="${2:-}" exe pids count
  exe="$(bundle_executable "$bundle")" || refuse "$bundle is not an app bundle"
  if [ -n "$given" ]; then
    [ "$(pid_executable "$given")" = "$exe" ] ||
      refuse "pid $given is not running from $bundle — refusing to quit it"
    echo "$given"
    return
  fi
  pids="$(bundle_pids "$bundle")"
  count="$(printf '%s' "$pids" | grep -c .)"
  [ "$count" -eq 1 ] ||
    refuse "$count processes are running from $bundle (${pids//$'\n'/ }); pass --pid"
  echo "$pids"
}

# BundleSwap.script, read out of the Swift source rather than copied: the swap that the
# in-app update badge runs is the one this runs. ReleaseResumeScriptTests holds the extraction
# equal to the compiled constant, so an escape or interpolation added to the literal fails a
# test instead of changing what runs here.
swap_script() {
  awk '/static let script = """/ { inside = 1; next }
       inside && /^        """$/ { exit }
       inside { sub(/^        /, ""); print }' "$repo/Sources/Helm/Build/BundleSwap.swift"
}

sessions_dir() { printf '%s\n' "$HOME/.claude/sessions"; }

# Live pids holding the session: rows in Claude Code's registry naming it, whose pid is alive.
session_pids() {
  local row pid
  for row in $(grep -lsF "\"sessionId\":\"$1\"" "$(sessions_dir)"/*.json); do
    pid="$(plutil -extract pid raw "$row" 2>/dev/null)" || continue
    alive "$pid" && echo "$pid"
  done
}

session_field() {
  local row
  row="$(grep -lsF "\"sessionId\":\"$1\"" "$(sessions_dir)"/*.json | head -1)"
  [ -n "$row" ] && plutil -extract "$2" raw "$row" 2>/dev/null
}

descends_from() {
  local pid="$1" ancestor="$2" steps=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$steps" -lt 64 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    steps=$((steps + 1))
  done
  return 1
}

# ---- arguments ----------------------------------------------------------------------------------

session="" cwd="" bundle="/Applications/Helm.app" pid="" suite="" bench_suite=""
cargo_root="" remote_control=1 detached_log=""
extra_env=()

parse() {
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --bundle) bundle="${2:?--bundle needs a path}"; shift 2 ;;
    --pid) pid="${2:?--pid needs a pid}"; shift 2 ;;
    --suite) suite="${2:?--suite needs a name}"; shift 2 ;;
    --bench-suite) bench_suite="${2:?--bench-suite needs a name}"; shift 2 ;;
    --cargo-root) cargo_root="${2:?--cargo-root needs a directory}"; shift 2 ;;
    --env) extra_env+=("${2:?--env needs KEY=VALUE}"); shift 2 ;;
    --no-remote-control) remote_control=0; shift ;;
    --detached) detached_log="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$self" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "release-resume: unknown option $1" >&2; exit 1 ;;
    *) positional+=("$1"); shift ;;
    esac
  done
  session="${positional[0]:-}"
  cwd="${positional[1]:-}"
  [ "${#positional[@]}" -le 2 ] || { echo "release-resume: too many arguments" >&2; exit 1; }
  [ -n "$session" ] || { echo "usage: release-resume.sh <session-id> [cwd] [options]" >&2; exit 1; }
  bench_suite="${bench_suite:-$suite}"
  local kv
  for kv in ${extra_env[@]+"${extra_env[@]}"}; do
    [[ "$kv" == [A-Za-z_]*=* ]] || { echo "release-resume: --env $kv is not KEY=VALUE" >&2; exit 1; }
    # These move where helm and benchd keep their state. The script waits on the snapshot, resumes
    # through benchd and restarts it by the suites alone, so an override here would point the
    # new helm somewhere the script never looks. Isolate with --suite and --bench-suite instead.
    case "${kv%%=*}" in
    HELM_DEFAULTS_SUITE | BENCH_SUITE | HELM_BENCH_DIR | BENCH_DIR)
      echo "release-resume: --env ${kv%%=*} is not supported; use --suite and --bench-suite" >&2
      exit 1
      ;;
    esac
  done
}

# The arguments the detached run gets: everything resolved, nothing left to guess later.
forwarded() {
  local out=("$session" "$cwd" --bundle "$bundle" --pid "$pid")
  [ -n "$suite" ] && out+=(--suite "$suite")
  [ -n "$bench_suite" ] && out+=(--bench-suite "$bench_suite")
  [ -n "$cargo_root" ] && out+=(--cargo-root "$cargo_root")
  local kv
  for kv in ${extra_env[@]+"${extra_env[@]}"}; do out+=(--env "$kv"); done
  [ "$remote_control" -eq 0 ] && out+=(--no-remote-control)
  printf '%s\0' "${out[@]}"
}

# ---- the foreground half: check, then detach ----------------------------------------------------

check() {
  [[ "$session" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    refuse "$session is not a session id (a UUID, as in ~/.claude/sessions/*.json)"
  [ -d "$bundle" ] || refuse "no bundle at $bundle"
  [ -n "$(swap_script)" ] || refuse "cannot read BundleSwap.script out of $repo/Sources/Helm/Build/BundleSwap.swift"
  pid="$(resolve_helm_pid "$bundle" "$pid")" || exit 3

  # The session must be inside the helm being quit. One that is not keeps running, and resuming
  # it would start a second copy of the same conversation.
  local holders holder inside=0
  holders="$(session_pids "$session")"
  for holder in $holders; do descends_from "$holder" "$pid" && inside=1; done
  [ -n "$holders" ] || refuse "no live process holds session $session"
  [ "$inside" -eq 1 ] || refuse "session $session (pid $holders) is not running inside helm pid $pid"

  if [ -z "$cwd" ]; then
    cwd="$(session_field "$session" cwd)" || refuse "cannot read the cwd of $session; pass it"
  fi
  [ -d "$cwd" ] || refuse "no directory $cwd"

  local tool
  for tool in timeout claude cargo swift make xcodegen perl; do
    command -v "$tool" >/dev/null || refuse "$tool is not on PATH"
  done
}

detach() {
  local build_dir stamp state
  build_dir="${HELM_BUILD_DIR:-$HOME/.helm/build}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  state="$build_dir/release-resume-$stamp"
  mkdir -p "$state" || refuse "cannot create $state"
  ln -sfn "$state/log" "$build_dir/release-resume.log"

  local args=()
  while IFS= read -r -d '' a; do args+=("$a"); done < <(forwarded)
  # Double fork, nohup and a new session: the run survives the pane it was started from, and
  # the pty's hangup never reaches it.
  (
    (
      exec nohup /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' \
        /bin/bash "$self" --detached "$state/log" "${args[@]}" </dev/null >>"$state/log" 2>&1 &
    ) &
  )
  echo "release-resume: detached; log at $state/log"
  echo "release-resume: helm pid $pid ($bundle) will be quit, session $session resumed in $cwd"
}

# ---- the detached half ------------------------------------------------------------------------

phase="before-quit"
fallback_reason=""

finish() {
  log "RESULT: $*"
  exit "${exit_code:-0}"
}

# Everything after the quit comes here on failure: the session is resumed outside helm so the
# operator can still reach it.
fail() {
  log "FAILED: $*"
  if [ "$phase" = "before-quit" ]; then
    exit_code=1 finish "failed before quitting helm; helm and the session are untouched — $*"
  fi
  fallback_reason="$*"
  fallback
}

detached_run() {
  log "release-resume $session in $cwd; bundle $bundle, pid $pid, suite '${suite}', bench suite '${bench_suite}', remote control $remote_control"

  # Detached means init is our parent. Until then, a quit could still reach us through the pane.
  local deadline=$(($(date +%s) + 10))
  until [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "1" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && exit_code=1 finish "never detached (ppid $(ps -o ppid= -p $$)); nothing touched"
    sleep 0.1
  done
  log "detached: pid $$, ppid 1, session leader $(ps -o sess= -p $$ | tr -d ' ')"

  # The caller's own session variables must not reach the new helm or the resumed agent: the
  # caller is usually the very session being resumed. Suites come only from the flags.
  local v
  for v in $(compgen -e); do
    case "$v" in CLAUDECODE | CLAUDE_CODE_* | CLAUDE_PID | HELM_PANE | HELM_DEFAULTS_SUITE | \
      BENCH_SUITE | BENCH_DIR | HELM_BENCH_DIR) unset "$v" ;; esac
  done

  log "checkout $(git -C "$repo" rev-parse --short HEAD) on $(git -C "$repo" rev-parse --abbrev-ref HEAD)$(git -C "$repo" diff --quiet HEAD || echo ', dirty')"

  # 1. Build. Nothing has been touched yet, so a failure here just stops. The compiler's output
  # goes to its own file, so this log stays short enough to read from a phone.
  local build_log="${detached_log%/log}/build.log"
  log "step 1: make release (output in $build_log)"
  timeout 1800 make -C "$repo" release >>"$build_log" 2>&1 || { tail -30 "$build_log"; fail "make release"; }
  local product="$repo/.build/DerivedData/Build/Products/Release/Helm.app" sha
  sha="$(/usr/libexec/PlistBuddy -c "Print :HelmBuildSHA" "$product/Contents/Info.plist" 2>/dev/null)" ||
    fail "the built product carries no HelmBuildSHA"
  log "built $sha at $product"

  local bin crate
  bin="${cargo_root:-${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}}/bin"
  for crate in "${agent_crates[@]}"; do
    log "step 1: cargo install $crate into $bin"
    timeout 1200 cargo install --locked --force --path "$repo/daemon/crates/$crate" \
      --target-dir "$repo/daemon/target" ${cargo_root:+--root "$cargo_root"} >>"$build_log" 2>&1 ||
      { tail -30 "$build_log"; fail "cargo install $crate"; }
  done

  # 2. Quit helm, by pid. Re-checked here because minutes have passed since the foreground check.
  [ "$(resolve_helm_pid "$bundle" "$pid")" = "$pid" ] || fail "pid $pid no longer runs $bundle"
  local old_session_pids
  old_session_pids="$(session_pids "$session")"
  log "step 2: quitting helm pid $pid (session held by ${old_session_pids:-nobody})"
  phase="after-quit"
  timeout 20 /usr/bin/osascript -l JavaScript -e "ObjC.import('AppKit');
    var app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid);
    app.isNil() ? 'gone' : String(app.terminate)" || log "quit request failed; the swap waits anyway"

  # 3. benchd, while helm is down, so the new helm starts against the new daemon.
  restart_benchd "$bin"

  # 4. Swap and relaunch, through BundleSwap's own script. It waits for the pid (60s), stages,
  # renames and rolls back; every failure path relaunches whatever is installed.
  local launcher="${detached_log%/log}/launch-helm.sh"
  write_launcher "$launcher"
  local relaunched_at
  relaunched_at="$(date +%s)"
  # Displays asleep means no terminal can be created in the new helm (CoreVideo -6661). Hold
  # them awake for as long as the relaunch and the resume can take; caffeinate bounds itself.
  caffeinate -d -u -t 600 &
  log "step 4: swapping $bundle for $product"
  timeout 600 /bin/sh -c "$(swap_script)" helm-update "$pid" "$product" "$bundle" 60 "$launcher"
  local swap=$?
  # 2–4 are BundleSwap's own failures, each of which restores and relaunches. Exit 1 is its
  # deadline only while helm is still alive: BundleSwap ends on the launcher, so a relaunch that
  # fails after a good swap also returns 1. That, and anything else (this timeout killing a copy
  # midway), leaves the bundle in a state only a listing can tell.
  if [ "$swap" -eq 1 ] && alive "$pid"; then
    fail "helm pid $pid did not exit within 60s; nothing was swapped"
  fi
  case "$swap" in
  0) log "swapped; relaunched through $launcher" ;;
  2 | 3 | 4) fail "the swap failed with exit $swap; the previous bundle was restored and relaunched" ;;
  *)
    ls -ld "$bundle" "$bundle.helm-update" "$bundle.helm-previous" 2>&1
    fail "the swap ended with exit $swap; the bundle's state is unknown, see the listing above"
    ;;
  esac

  # 5. The new helm is up when its bench snapshot is written after the relaunch.
  local new_pid="" written deadline=$(($(date +%s) + 90))
  local snapshot="$HOME/.helm/bench${suite:+-$suite}/snapshot.json"
  while :; do
    [ "$(date +%s)" -ge "$deadline" ] && fail "the new helm never wrote $snapshot"
    new_pid="$(bundle_pids "$bundle" | grep -vx "$pid" | head -1)"
    written="$(plutil -extract writtenAt raw "$snapshot" 2>/dev/null)"
    if [ -n "$new_pid" ] && [ -n "$written" ] &&
      [ "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$written" +%s 2>/dev/null || echo 0)" -ge "$relaunched_at" ]; then
      break
    fi
    sleep 1
  done
  log "step 5: new helm pid $new_pid, snapshot written $written"

  # The old agent dies with its pane. Resuming while it lives would fork the conversation.
  local held
  deadline=$(($(date +%s) + 30))
  while held="$(session_pids "$session")" && [ -n "$held" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && fail "session $session is still held by pid $held after helm quit"
    sleep 0.5
  done

  # 6. Resume in a benchd pty, shown in a pane of the new helm (`bench spawn --resume`). The
  # registry row is the proof, and it is what gets checked next.
  local notice="${detached_log%/log}/resume-notice.md"
  printf 'helm was rebuilt and restarted by release-resume; this session resumed on build %s. Log: %s.\n' \
    "$sha" "$detached_log" >"$notice"
  log "step 6: bench spawn --resume $session"
  resume_in_bench "$bin" "$session" "$cwd" "$notice" "$sha" || fail "bench spawn exited $?"

  local resumed
  resumed="$(await_session "$old_session_pids")" || fail "no live process took up session $session"
  finish "resumed-in-helm — session $session, pid $resumed, helm pid $new_pid, build $sha$(rc_state)"
}

warn() { log "WARNING: $*"; }

# Resume <session> in a benchd pty, shown in a pane of <cwd>'s workspace and brought forward
# (`--asked`: the operator is driving this session). Remote Control rides after the posture as
# a flag of claude's own. The notice file is the session's next message, and outlives the spawn.
resume_in_bench() (
  local bin="$1" session="$2" cwd="$3" notice="$4" sha="$5"
  [ -n "$bench_suite" ] && export BENCH_SUITE="$bench_suite"
  local rc_args=()
  [ "$remote_control" -eq 1 ] && rc_args=(--arg --remote-control --arg "helm $sha")
  timeout 60 "$bin/bench" spawn --agent claude --cwd "$cwd" --resume "$session" \
    --prompt-file "$notice" --asked ${rc_args[@]+"${rc_args[@]}"}
)

# A subshell, so BENCH_SUITE is set for bench and benchd only. It is exported only when there is
# a suite: an empty BENCH_SUITE is a refusal to bench, not the live instance.
restart_benchd() (
  local bin="$1" logfile="$HOME/Library/Logs/benchd${bench_suite:+-$bench_suite}.log" deadline
  [ -n "$bench_suite" ] && export BENCH_SUITE="$bench_suite"

  # When launchd runs benchd (scripts/benchd-agent.sh), launchd restarts it. Stopping it here and
  # starting another by hand would leave the agent down and a second, unmanaged benchd in its
  # place. The browser is benchd's to bring back (<root>/browser/wanted).
  local label loaded
  label="$(agent_label "$bench_suite")"
  agent_loaded "$label"
  loaded=$?
  # Unknown is not "not loaded": starting a benchd here could put a second one beside launchd's.
  if [ "$loaded" -eq 124 ]; then
    warn "launchctl did not answer whether $label is loaded; leaving benchd as it is"
    return
  fi
  if [ "$loaded" -eq 0 ]; then
    local before
    before="$(bench_pid "$bin/bench")"
    log "step 3: restarting benchd through launchd ($label, pid ${before:-none})"
    timeout 30 launchctl kickstart -k "gui/$(id -u)/$label" || { warn "launchctl kickstart failed"; return; }
    deadline=$(($(date +%s) + 30))
    local now
    until now="$(bench_pid "$bin/bench")" && [ -n "$now" ] && [ "$now" != "$before" ]; do
      [ "$(date +%s)" -ge "$deadline" ] && { warn "benchd did not come back under launchd; see $logfile"; return; }
      sleep 0.2
    done
    log "benchd pid $now under launchd"
    return
  fi

  log "step 3: restarting benchd (suite '${bench_suite}') from $bin, log $logfile"
  timeout 20 "$bin/bench" stop
  deadline=$(($(date +%s) + 20))
  while timeout 5 "$bin/bench" status >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && { warn "benchd did not stop; leaving it"; return; }
    sleep 0.2
  done
  # Its own session, like the live one: benchd is meant to outlive this script.
  (
    exec nohup /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' \
      "$bin/benchd" </dev/null >>"$logfile" 2>&1 &
  )
  deadline=$(($(date +%s) + 20))
  until timeout 5 "$bin/bench" status >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && { warn "benchd did not come back; see $logfile"; return; }
    sleep 0.2
  done
  timeout 90 "$bin/bench" browser start || warn "bench browser start failed"
)

# The relaunch: `open` hands the app the caller's whole environment, so start from launchd's
# (what the Dock gives helm) and add only the suite and --env values.
write_launcher() {
  local base=(HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}"
    TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin)
  [ -n "${SSH_AUTH_SOCK:-}" ] && base+=(SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
  local envs=()
  [ -n "$suite" ] && envs+=(--env "HELM_DEFAULTS_SUITE=$suite")
  [ -n "$bench_suite" ] && envs+=(--env "BENCH_SUITE=$bench_suite")
  local kv
  for kv in ${extra_env[@]+"${extra_env[@]}"}; do envs+=(--env "$kv"); done
  {
    echo '#!/bin/bash'
    printf 'exec /usr/bin/env -i'
    printf ' %q' "${base[@]}" /usr/bin/open -n
    printf ' "$1"'
    [ "${#envs[@]}" -gt 0 ] && printf ' %q' "${envs[@]}"
    echo
  } >"$1"
  chmod 700 "$1"
}

# Wait for a live process, other than the ones that held it before, to hold the session.
await_session() {
  local before="$1" deadline=$(($(date +%s) + 90)) p
  while [ "$(date +%s)" -lt "$deadline" ]; do
    for p in $(session_pids "$session"); do
      if ! grep -qx "$p" <<<"$before"; then
        if [ "$remote_control" -eq 0 ] || [ -n "$(session_row_field "$p" bridgeSessionId)" ]; then
          echo "$p"
          return 0
        fi
      fi
    done
    sleep 1
  done
  # A process that took the session without Remote Control coming up is still a resume.
  for p in $(session_pids "$session"); do
    grep -qx "$p" <<<"$before" || { warn "pid $p holds the session but Remote Control never came up" >&2; echo "$p"; return 0; }
  done
  return 1
}

session_row_field() { plutil -extract "$2" raw "$(sessions_dir)/$1.json" 2>/dev/null; }

rc_state() {
  [ "$remote_control" -eq 1 ] || { echo ", remote control off"; return; }
  local p bridge
  for p in $(session_pids "$session"); do
    bridge="$(session_row_field "$p" bridgeSessionId)" && echo ", remote control $bridge" && return
  done
  echo ", remote control NOT up"
}

# The session must never be left unreachable: resume it in the background, outside helm.
fallback() {
  if [ -n "$(session_pids "$session")" ]; then
    exit_code=1 finish "failed after quitting helm ($fallback_reason), but pid $(session_pids "$session" | tr '\n' ' ')holds session $session, so no fallback"
  fi
  log "FALLBACK: resuming $session outside helm with claude --bg, because: $fallback_reason"
  local rc_args=()
  [ "$remote_control" -eq 1 ] && rc_args=(--remote-control "helm fallback")
  (cd "$cwd" && timeout 90 claude --bg --resume "$session" --dangerously-skip-permissions \
    ${rc_args[@]+"${rc_args[@]}"} \
    "release-resume could not bring this session back inside helm ($fallback_reason), so it resumed in the background instead. Log: $detached_log.") ||
    exit_code=1 finish "failed ($fallback_reason) AND the fallback claude --bg failed; session $session is not running"
  local resumed
  resumed="$(await_session "")" || exit_code=1 finish "failed ($fallback_reason); claude --bg started but no process holds $session"
  exit_code=1 finish "fallback — session $session resumed outside helm as pid $resumed (claude attach ${session:0:8})$(rc_state); reason: $fallback_reason"
}

main() {
  parse "$@"
  if [ -n "$detached_log" ]; then
    detached_run
  else
    check
    detach
  fi
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
