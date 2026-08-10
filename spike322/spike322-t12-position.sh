#!/bin/bash
# spike322 T12 — what IS an agent's position? `push.sh`'s header measured this; measure it
# again here, so every verdict in this spike can name the seat it was proved from.
echo "=== the four `push.sh` measures, from THIS agent's tool call ==="
echo "tty:            $(tty 2>&1)"
echo "session (ps):   $(ps -o sess= -p $$ 2>/dev/null | tr -d ' ')"
printf '/dev/tty:       '; if : < /dev/tty 2>/dev/null; then echo "openable"; else echo "NOT openable"; fi
if [ -t 1 ]; then echo "[ -t 1 ]:       true"; else echo "[ -t 1 ]:       FALSE (stdout is not a terminal)"; fi
if [ -t 0 ]; then echo "[ -t 0 ]:       true"; else echo "[ -t 0 ]:       FALSE"; fi

echo
echo "=== where stdout actually goes ==="
ls -l /proc/self/fd 2>/dev/null || lsof -a -p $$ -d 0,1,2 2>/dev/null | awk 'NR==1||/[012][ru]/'

echo
echo "=== my ancestry — the chain bench-mail walks ==="
pid=$$
for i in 1 2 3 4 5 6 7 8; do
  read -r ppid comm <<< "$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)"
  [ -z "$ppid" ] && break
  echo "  $pid  $(ps -o comm= -p "$pid" 2>/dev/null)"
  pid=$ppid
  [ "$pid" -le 1 ] && break
done

echo
echo "=== helm pane environment visible here? ==="
echo "HELM_PANE=${HELM_PANE:-(unset)}"
echo "HELM_MAIL_HANDLE=${HELM_MAIL_HANDLE:-(unset)}"
echo "HELM_DEFAULTS_SUITE=${HELM_DEFAULTS_SUITE:-(unset)}"
echo "TERM=${TERM:-(unset)}"
