#!/usr/bin/env bash
# Does a backgrounded helm tab stall its child process?
#
# A detached tab's ghostty_app_t receives no ghostty_app_tick (the canRenderFrame
# gate in TerminalSurfaceCoordinator blocks both the wakeup and the scheduled
# path). Whether that stalls the CHILD depends on where libghostty drains the
# pty — undecidable from the Swift layer, so measure it.
#
# The child stamps every line with its OWN clock and flushes. If the pty fills
# and nobody drains it, the child blocks in write() and its timestamps stop —
# a wall-clock gap in the log is the proof. Timestamps taken by the reader
# would be invisible to this.
#
#   run    generate the stream (run this IN the helm tab you will background)
#   check  scan a log for the largest inter-line gap
#
# Owner procedure (agents must not run helm):
#   1. Open two helm tabs.
#   2. In tab 2:  bash tools/ptystall.sh run
#   3. Watch it pass "64 KiB written" (a few seconds), then switch to tab 1.
#   4. Wait 60s. Switch back. ⌃C the script.
#   5. bash tools/ptystall.sh check <the log path it printed>
#      A gap ≈ the time you were away  → STALLS.
#      Gaps in the milliseconds        → DOES-NOT-STALL.
#   6. Re-run all of this after the shared-controller change and compare.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-run}

# ~1000 lines/sec, paced in blocks of 100. A slow echo loop would never fill the
# 64 KiB pty buffer and would report a false DOES-NOT-STALL; this clears 64 KiB
# in a couple of seconds. Rate only sets how fast the buffer fills — once it is
# full and undrained the child stays blocked, so faster is not more sensitive,
# just a bigger log.
block=100
block_sleep=0.1

case "$mode" in
run)
  mkdir -p "$root/tools/measurements"
  log="$root/tools/measurements/ptystall-$(date +%s).log"
  echo "logging to $log"
  echo "switch away AFTER you see '64 KiB written', stay away 60s, come back, then ^C"
  echo

  if [ -n "${EPOCHREALTIME:-}" ]; then
    # bash 5+: high-resolution clock without leaving the shell.
    i=0
    bytes=0
    announced=0
    while :; do
      i=$((i + 1))
      line="$i ${EPOCHREALTIME}"
      printf '%s\n' "$line"
      printf '%s\n' "$line" >>"$log"
      bytes=$((bytes + ${#line} + 1))
      if [ "$announced" -eq 0 ] && [ "$bytes" -gt 65536 ]; then
        announced=1
        printf '>>> 64 KiB written — switch away now\n'
      fi
      if [ $((i % block)) -eq 0 ]; then sleep "$block_sleep"; fi
    done
  else
    # macOS /bin/bash is 3.2 and has no EPOCHREALTIME, and BSD `date` has no
    # %N. perl is always present and its clock is the child's own.
    echo "(bash < 5 — using perl for the high-resolution clock)"
    perl -e '
      use Time::HiRes qw(time sleep);
      $| = 1;
      open(my $log, ">>", $ARGV[0]) or die $!;
      select((select($log), $| = 1)[0]);
      my ($i, $bytes, $announced) = (0, 0, 0);
      while (1) {
        $i++;
        my $line = sprintf("%d %.6f", $i, time());
        print "$line\n";
        print $log "$line\n";
        $bytes += length($line) + 1;
        if (!$announced && $bytes > 65536) {
          $announced = 1;
          print ">>> 64 KiB written — switch away now\n";
        }
        sleep('"$block_sleep"') if $i % '"$block"' == 0;
      }
    ' "$log"
  fi
  ;;

check)
  log=${2:-}
  [ -n "$log" ] || { echo "usage: $0 check <log>" >&2; exit 2; }
  [ -f "$log" ] || { echo "no such log: $log" >&2; exit 1; }

  awk '
    NF < 2 { next }
    {
      if (previous != "") {
        gap = $2 - previous
        if (gap > worst) { worst = gap; at = $1 }
      }
      previous = $2
      first = (first == "" ? $2 : first)
      last = $2
      count++
    }
    END {
      if (count < 2) { print "not enough lines"; exit 1 }
      printf "lines:        %d\n", count
      printf "wall clock:   %.3fs\n", last - first
      printf "largest gap:  %.3fs (before line %s)\n", worst, at
      printf "\nverdict:      %s\n", (worst > 1.0 ? "STALLS" : "DOES-NOT-STALL")
      if (worst > 1.0)
        print "the child blocked in write() — a backgrounded tab does not drain its pty"
      else
        print "the child never blocked — libghostty drains the pty off the tick path"
    }
  ' "$log"
  ;;

*)
  echo "usage: $0 [run|check <log>]" >&2
  exit 2
  ;;
esac
