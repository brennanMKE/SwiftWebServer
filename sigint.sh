#!/bin/bash

PORT=8080

PID=$(lsof -ti tcp:$PORT)

if [ -z "$PID" ]; then
  echo "No process is listening on port $PORT."
  exit 1
fi

echo "Sending SIGINT (kill -2) to PID $PID using port $PORT..."
kill -2 "$PID"
