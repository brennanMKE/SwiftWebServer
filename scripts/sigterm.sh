#!/bin/bash

cd "$(dirname "$0")/.."

PORT=8080

PID=$(lsof -ti tcp:$PORT)

if [ -z "$PID" ]; then
  echo "No process is listening on port $PORT."
  exit 1
fi

echo "Sending SIGTERM to PID $PID using port $PORT..."
kill -TERM "$PID"
