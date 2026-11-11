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

WATCH_NAMES="SecurityAgent CoreServicesUIAgent UserNotificationCenter"
watch_pids() { for n in $WATCH_NAMES; do pgrep -x "$n"; done | sort -u | tr '\n' ' '; }
baseline=$(watch_pids)

# Start the command in its own process group (perl setpgrp works without job control).
perl -e 'setpgrp(0,0); exec @ARGV or die "exec: $!"' -- "$@" &
CMD=$!
start=$(date +%s)
status=""
suspects=""

# All descendants of a pid, deepest first. Tools such as `swift test` start
# helpers in their own process groups, so killing our group is not enough.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    descendants "$child"
    echo "$child"
  done
}

kill_cmd() {
  local tree
  tree="$(descendants "$CMD")"
  kill -TERM -"$CMD" 2>/dev/null || kill -TERM "$CMD" 2>/dev/null
  [ -n "$tree" ] && kill -TERM $tree 2>/dev/null
  sleep 2
  kill -KILL -"$CMD" 2>/dev/null || kill -KILL "$CMD" 2>/dev/null
  [ -n "$tree" ] && kill -KILL $tree 2>/dev/null
}

while kill -0 "$CMD" 2>/dev/null; do
  sleep 1
  now=$(date +%s)
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    echo "guarded.sh: TIMEOUT after ${TIMEOUT}s: $*" >&2
    kill_cmd; status=124; break
  fi
  # A prompt is a watched process (exact name) that was not in the baseline
  # and is still alive on two consecutive checks; this ignores short-lived
  # processes that exit before they can show anything.
  current=""
  for pid in $(watch_pids); do
    case " $baseline " in *" $pid "*) continue ;; esac
    name=$(ps -o comm= -p "$pid" 2>/dev/null)
    [ -z "$name" ] && continue
    current="$current $pid"
    case " $suspects " in
      *" $pid "*)
        echo "guarded.sh: SYSTEM PROMPT DETECTED ($name, pid $pid); killing: $*" >&2
        echo "guarded.sh: a keychain, firewall, or privacy prompt was triggered. Do not retry the same way; see AGENTS.md." >&2
        kill_cmd; status=125; break 2 ;;
    esac
  done
  suspects="$current"
done

if [ -z "$status" ]; then wait "$CMD"; status=$?; fi
exit "$status"
