#!/bin/bash
set -euo pipefail
if [ "${1:-}" != --bounded ]; then
  exec timeout -k 5 1150 "$0" --bounded "$@"
fi
shift
WT=${OOPIF_TEST_WT:-$(cd "$(dirname "$0")/.." && pwd)}
WT=$(cd "$WT" && pwd)
ROOT=$(mktemp -d /tmp/oopif-live.XXXXXX)
export BENCH_DIR="$ROOT" BENCH_SUITE="oopif-live-$$" HELM_DEFAULTS_SUITE="oopif-live-$$"
unset BENCH_SESSION BENCH_HANDLE BENCH_ASKED HELM_PANE BENCH_URL BENCH_LISTEN HELM_BENCH_DIR
DAEMON_PID='' SERVER_PID='' ACTUAL_DAEMON_PID='' ACTUAL_SERVER_PID='' BROWSER_PID=''
cleanup() {
  local result=$?
  timeout 15 bench browser stop >/dev/null 2>&1 || true
  for owned in "$SERVER_PID" "$DAEMON_PID"; do
    if [ -n "$owned" ]; then kill "$owned" 2>/dev/null || true; wait "$owned" 2>/dev/null || true; fi
  done
  for ((n=0;n<20;n++)); do
    if [ -z "$BROWSER_PID" ] || ! kill -0 "$BROWSER_PID" 2>/dev/null; then break; fi
    sleep .1
  done
  for owned in "$ACTUAL_SERVER_PID" "$ACTUAL_DAEMON_PID" "$BROWSER_PID"; do
    if [ -n "$owned" ]; then
      if ps -p "$owned" -o pid=,command=; then
        echo "oopif cleanup FAILED: owned pid $owned remains"; result=1
      else
        echo "oopif cleanup: owned pid $owned is gone"
      fi
    fi
  done
  timeout 5 defaults delete "$HELM_DEFAULTS_SUITE" >/dev/null 2>&1 || true
  rm -rf "$ROOT"
  ps -Ao pcpu,etime,pid,command -r | head -12 || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
mkdir -p "$ROOT/browser"
printf '{"mock_keychain":true}\n' > "$ROOT/browser/config.json"
timeout -k 3 1100 benchd > "$ROOT/benchd.log" 2>&1 & DAEMON_PID=$!
timeout -k 3 1100 node "$WT/Tests/BrowserFixtures/oopif.mjs" "$ROOT/fixture.url" > "$ROOT/fixture.log" 2>&1 & SERVER_PID=$!
for ((n=0;n<100;n++)); do
  if [ -S "$ROOT/benchd.sock" ] && [ -s "$ROOT/fixture.url" ]; then break; fi
  sleep .1
done
test -S "$ROOT/benchd.sock"
test -s "$ROOT/fixture.url"
ACTUAL_SERVER_PID=$(pgrep -P "$SERVER_PID")
timeout 10 bench status > "$ROOT/status.json"
ACTUAL_DAEMON_PID=$(timeout 10 node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).pid' "$ROOT/status.json")
timeout 60 bench browser start > "$ROOT/start.json"
cat "$ROOT/start.json"
BROWSER_PID=$(timeout 10 node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).pid' "$ROOT/start.json")
echo "oopif owned pids: daemon=$ACTUAL_DAEMON_PID node=$ACTUAL_SERVER_PID browser=$BROWSER_PID"
export HELM_BROWSER_LIVE_BENCH_DIR="$ROOT" INJECTION_NOGENERICS=1
export HELM_BROWSER_OOPIF_URL=$(cat "$ROOT/fixture.url")
cd "$WT"
FILTER=${1:-BrowserOOPIF}
if [ "$#" -gt 0 ]; then shift; fi
timeout -k 3 900 swift test --disable-keychain "$@" --filter "$FILTER"
