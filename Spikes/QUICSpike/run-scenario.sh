#!/bin/bash
# Runs the spike server (loopback, ephemeral port) under scripts/guarded.sh, then one client
# command with PORT substituted, then stops the server. Prints both logs.
#
#   ./run-scenario.sh [--server-args "..."] -- <client command with PORT placeholder>
#   ./run-scenario.sh -- .build/debug/quic-client echo --port PORT
#   ./run-scenario.sh -- /opt/homebrew/opt/curl/bin/curl -sv --http3-only -k https://127.0.0.1:PORT/
set -u
cd "$(dirname "$0")"
GUARD="${GUARD:-../../scripts/guarded.sh}"
SERVER_ARGS=""
if [ "${1:-}" = "--server-args" ]; then SERVER_ARGS="$2"; shift 2; fi
[ "${1:-}" = "--" ] && shift
LOG_DIR="${TMPDIR:-/tmp}/quic-spike.$$"
mkdir -p "$LOG_DIR"
SLOG="$LOG_DIR/server.log"

# shellcheck disable=SC2086
"$GUARD" -t "${SERVER_TIMEOUT:-90}" -- ${BIN:-.build/debug}/quic-server $SERVER_ARGS >"$SLOG" 2>&1 &
SPID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT=$(sed -n 's/.*listener state ready port=\([0-9]*\).*/\1/p' "$SLOG" | head -1)
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then echo "server did not start"; cat "$SLOG"; kill "$SPID" 2>/dev/null; exit 1; fi

CMD=()
for a in "$@"; do CMD+=("${a//PORT/$PORT}"); done
echo "=== client: ${CMD[*]}"
"$GUARD" -t "${CLIENT_TIMEOUT:-30}" -- "${CMD[@]}" 2>&1
echo "=== client exit $?"
sleep "${SETTLE:-0.5}"
pkill -TERM -P "$SPID" 2>/dev/null
wait "$SPID" 2>/dev/null
echo "=== server log"
cat "$SLOG"
rm -rf "$LOG_DIR"
