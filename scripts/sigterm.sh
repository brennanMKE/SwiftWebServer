#!/bin/bash
# Sends SIGTERM to the process listening on PORT (default 8080); the server drains open
# connections and exits 0.

cd "$(dirname "$0")/.."

PORT=${PORT:-8080}

PID=$(lsof -ti tcp:"$PORT" -sTCP:LISTEN)

if [ -z "$PID" ]; then
  echo "No process is listening on port $PORT."
  exit 1
fi

echo "Sending SIGTERM to PID $PID using port $PORT..."
kill -TERM $PID
