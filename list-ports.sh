#!/bin/bash

# Usage:
#   ./list-ports-for-pids.sh            # lists ports for all SwiftWebServer processes
#   ./list-ports-for-pids.sh 1234 5678  # lists ports for given PIDs

# If no arguments are given, use all SwiftWebServer PIDs
if [ "$#" -eq 0 ]; then
  PIDS=$(pgrep SwiftWebServer)
else
  PIDS="$@"
fi

if [ -z "$PIDS" ]; then
  echo "No matching processes found."
  exit 0
fi

for PID in $PIDS; do
  echo "PID $PID:"
  # List all ports this PID is using (listening or connected)
  lsof -nP -iTCP -a -p "$PID" | awk '
    NR > 1 {
      split($9, parts, ":")
      port = parts[length(parts)]
      printf "  %-10s %s\n", $1, port
    }'
done
