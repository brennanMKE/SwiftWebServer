#!/bin/bash
# Run a command with a wall-clock timeout and a system-prompt watchdog.
#
#   scripts/guarded.sh [-t SECONDS] -- command args...
#
# Kills the command (and its process group) if:
#   - it runs longer than the timeout (default 600s), or
#   - a system prompt appears while it runs: a new SecurityAgent (keychain /
#     authorization dialogs), CoreServicesUIAgent, or a new
#     UserNotificationCenter alert process
#     (firewall, TCC) that was not running when the command started.
# Killing the requesting process dismisses the pending dialog.
#
# Exit codes: the command's own status; 124 on timeout; 125 on prompt detected.

TIMEOUT=600
if [ "$1" = "-t" ]; then TIMEOUT="$2"; shift 2; fi
[ "$1" = "--" ] && shift
[ "$#" -eq 0 ] && { echo "usage: $0 [-t seconds] -- command..." >&2; exit 2; }

WATCH='SecurityAgent|CoreServicesUIAgent|UserNotificationCenter'
baseline=$(pgrep -f "$WATCH" | sort | tr '\n' ' ')

set -m
"$@" &
CMD=$!
start=$(date +%s)
status=""

kill_cmd() {
  kill -TERM -"$CMD" 2>/dev/null || kill -TERM "$CMD" 2>/dev/null
  sleep 2
  kill -KILL -"$CMD" 2>/dev/null || kill -KILL "$CMD" 2>/dev/null
}

while kill -0 "$CMD" 2>/dev/null; do
  sleep 1
  now=$(date +%s)
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    echo "guarded.sh: TIMEOUT after ${TIMEOUT}s: $*" >&2
    kill_cmd; status=124; break
  fi
  for pid in $(pgrep -f "$WATCH"); do
    case " $baseline " in *" $pid "*) continue ;; esac
    echo "guarded.sh: SYSTEM PROMPT DETECTED ($(ps -o comm= -p "$pid" 2>/dev/null)); killing: $*" >&2
    echo "guarded.sh: a keychain, firewall, or privacy prompt was triggered. Do not retry the same way; see AGENTS.md." >&2
    kill_cmd; status=125; break 2
  done
done

if [ -z "$status" ]; then wait "$CMD"; status=$?; fi
exit "$status"
