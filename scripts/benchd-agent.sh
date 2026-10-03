#!/usr/bin/env bash
# benchd as a user LaunchAgent (#407): it starts at login and launchd restarts it after a crash.
#
#   scripts/benchd-agent.sh install [--no-build] [--listen <host:port|tailscale[:port]>]
#                                                    (or: just benchd-install …)
#   scripts/benchd-agent.sh uninstall                (or: just benchd-uninstall)
#
# install builds bench and benchd into cargo's bin (as release-resume does), writes
# ~/Library/LaunchAgents/com.wirasm.benchd.plist, stops a hand-started benchd if one answers,
# loads the agent, and starts the shared browser once. After that benchd brings the browser back
# by itself: it stays wanted until `bench browser stop` (daemon/direction.md).
#
# --listen also has benchd listen on TCP (BENCH_LISTEN), for Pocket on the operator's phone (#625).
# `tailscale` is this Mac's tailnet address (`tailscale ip -4`), port 4519 unless given, or
# 127.0.0.1 where Tailscale runs in userspace mode and forwards the tailnet there; either way the
# installer prints the tcp:// URL Pocket dials. The port has no login, so the tailnet is the trust
# boundary: `tailscale` that cannot be resolved stops the install, and never falls back to
# 0.0.0.0 or a LAN address. `<host>:<port>` is taken as the operator gives it, except an address
# that is every interface. An install without --listen writes an agent that does not listen, and
# says so when the one it replaces did.
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

# 0 loaded, 124 launchctl did not answer in time (so nobody knows), anything else not loaded.
agent_loaded() { timeout 10 launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }

# The binaries the agent runs and release-resume refreshes, installed from daemon/crates.
agent_crates=(bench benchd)

# The PATH the agent runs with: the installer's own, with ~/.local/bin moved to the front.
# benchd spawns claude, codex and pi by name, and launchd's default PATH
# (/usr/bin:/bin:/usr/sbin:/sbin) finds none of them. ~/.local/bin is where Claude Code's and
# codex's self-updating installers put their binaries, so it goes first: a stale Homebrew codex
# cask in /opt/homebrew/bin otherwise wins, and every spawned codex ran 0.157.0 while the
# standalone install had updated itself to 0.159.3. `bench status` names the binary and version
# each agent resolves to. Everything else in ~/.local/bin moves ahead too: on the operator's
# machine that includes node, npm and npx (Hermes's Node 22), which pi's `#!/usr/bin/env node`
# then runs under.
agent_path() {
  local first="$HOME/.local/bin" dir out="$HOME/.local/bin" IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] && [ "$dir" != "$first" ] && out="$out:$dir"
  done
  printf '%s\n' "$out"
}

# The port `--listen tailscale` binds when none is given.
agent_listen_port=4519

# The Tailscale CLI: on PATH, else the one inside the Mac app.
tailscale_cli() {
  command -v tailscale 2>/dev/null && return 0
  local app=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [ -x "$app" ] && printf '%s\n' "$app"
}

# resolve_listen <host:port|tailscale[:port]>: "<bind> <url>", the address benchd listens on and
# the URL Pocket dials, or a refusal on stderr and a non-zero status.
#
# `tailscale` is accepted only as an address in 100.64.0.0/10, where Tailscale puts every node;
# anything else it answers is not the tailnet. Where an interface carries that address, benchd
# binds it. In userspace mode (tailscaled --tun=userspace-networking, a user agent with its socket
# at ~/.tailscale/tailscaled.sock) none does: tailscaled takes the tailnet's connections itself and
# forwards each to 127.0.0.1 on the same port, so benchd binds loopback and Pocket still dials the
# tailnet address.
resolve_listen() {
  local spec="$1" host port cli bind
  local socket="$HOME/.tailscale/tailscaled.sock"
  case "$spec" in
  tailscale | tailscale:*)
    port="${spec#tailscale}"
    port="${port#:}"
    port="${port:-$agent_listen_port}"
    cli="$(tailscale_cli)" || {
      echo "benchd-agent: --listen tailscale needs Tailscale; it is not installed" >&2
      return 2
    }
    local ask=("$cli")
    [ -e "$socket" ] && ask+=(--socket "$socket")
    host="$(timeout 10 "${ask[@]}" ip -4 2>&1)" || {
      echo "benchd-agent: Tailscale has no address for this Mac (is it running and signed in?): $host" >&2
      return 2
    }
    host="${host%%$'\n'*}"
    if ! [[ "$host" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "benchd-agent: Tailscale answered '$host', which is not a tailnet address; not listening on it" >&2
      return 2
    fi
    local interfaces
    interfaces="$(ifconfig 2>/dev/null)"
    if [ -z "$interfaces" ]; then
      echo "benchd-agent: could not list this Mac's interfaces (ifconfig), so cannot tell where Tailscale delivers; not listening" >&2
      return 2
    fi
    if grep -qw "inet $host" <<<"$interfaces"; then
      bind="$host"
    else
      bind=127.0.0.1
      echo "benchd-agent: Tailscale runs in userspace mode here: it forwards tailnet connections to 127.0.0.1, so benchd listens there, and every port this Mac serves on 127.0.0.1 is reachable from your tailnet devices" >&2
    fi
    ;;
  *:*)
    host="${spec%:*}"
    port="${spec##*:}"
    # A dotted IPv4 address, a bracketed IPv6 one or a hostname, and never all zeros: whatever
    # else the resolver would read (0.0, 0x0, *, nothing) can mean every interface.
    local bare="${host#[}"
    bare="${bare%]}"
    if ! [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ ^\[[0-9A-Fa-f:.]+\]$ ||
      "$host" =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || [[ "$bare" =~ ^[0.:]+$ ]]; then
      echo "benchd-agent: --listen $spec listens on every interface, and the port has no login; name the tailnet address, or use --listen tailscale" >&2
      return 2
    fi
    bind="$host"
    ;;
  *)
    echo "benchd-agent: --listen takes <host>:<port> or tailscale[:<port>], not '$spec'" >&2
    return 2
    ;;
  esac
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "benchd-agent: --listen $spec: '$port' is not a port" >&2
    return 2
  fi
  printf '%s:%s tcp://%s:%s\n' "$bind" "$port" "$host" "$port"
}

# write_plist <path> <label> <benchd> <log> [suite] [listen]
write_plist() {
  local path="$1" label="$2" benchd="$3" logfile="$4" suite="${5:-}" listen="${6:-}"
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
    plutil -insert EnvironmentVariables.PATH -string "$(agent_path)" "$path" || return 1
  if [ -n "$suite" ]; then
    plutil -insert EnvironmentVariables.BENCH_SUITE -string "$suite" "$path" || return 1
  fi
  if [ -n "$listen" ]; then
    plutil -insert EnvironmentVariables.BENCH_LISTEN -string "$listen" "$path" || return 1
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
  local build=1 listen=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-build) build=0 ;;
    --listen)
      [ $# -ge 2 ] || { echo "benchd-agent: --listen needs <host>:<port> or tailscale" >&2; return 1; }
      listen="$2"
      shift
      ;;
    *) echo "benchd-agent: unknown option $1" >&2; return 1 ;;
    esac
    shift
  done
  # The agent is for the live root. Installed under either of these it would still boot the live
  # root (the plist carries neither), which is not what anyone setting them meant. An empty
  # BENCH_DIR is unset (#412); an empty BENCH_SUITE is a refusal to bench, so it refuses here too.
  if [ -n "${BENCH_SUITE+x}" ] || [ -n "${BENCH_DIR:-}" ]; then
    echo "benchd-agent: refusing to install with BENCH_SUITE or BENCH_DIR set — only the live benchd runs as a login agent; run a suite by hand" >&2
    return 3
  fi

  # Before anything is built or touched: an address that cannot be resolved changes nothing.
  local url=""
  if [ -n "$listen" ]; then
    read -r listen url <<<"$(resolve_listen "$listen")"
    [ -n "$listen" ] || return 2
    echo "benchd-agent: benchd will listen on $listen; Pocket's URL is $url"
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
  local listened
  listened="$(plutil -extract EnvironmentVariables.BENCH_LISTEN raw -o - "$plist" 2>/dev/null)"
  if [ -n "$listened" ] && [ -z "$listen" ]; then
    echo "benchd-agent: benchd no longer listens on $listened: Pocket cannot reach it until you install with --listen again"
  fi
  write_plist "$plist" "$label" "$bin/benchd" "$logfile" "" "$listen" ||
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
  [ -z "$url" ] || echo "benchd-agent: type $url into Pocket's connect sheet"

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
  *) echo "usage: benchd-agent.sh install [--no-build] [--listen <host:port|tailscale[:port]>] | uninstall" >&2; exit 1 ;;
  esac
fi
