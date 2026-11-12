#!/bin/bash
# Run the h2spec HTTP/2 conformance suite (#0061) against `sws-bench serve --h2-only`.
#
#   scripts/h2spec.sh [--tls] [--bin PATH] [--h2spec PATH] [--report FILE] [-- h2spec args...]
#
# Starts the server on 127.0.0.1 port 0 (cleartext, prior knowledge; or ALPN h2 over TLS
# with --tls, which needs scripts/make-test-identity.sh), runs h2spec against the printed
# port, stops the server and exits with h2spec's status. Extra arguments after `--` go to
# h2spec, for example a spec selector such as `http2/6.5`, or `-S` for the strict cases.
#
# The server serves HTTP/2 only (--h2-only). With `--h2` the cleartext port also serves
# HTTP/1.1, and h2spec's "invalid connection preface" case (3.5/2) then gets an HTTP/1.1 400,
# which is right for that port but not what h2spec expects (issues/0061.md).
#
# Install h2spec with `brew install h2spec`. Run it through the guard (AGENTS.md):
#   scripts/guarded.sh -t 300 -- scripts/h2spec.sh
#
# The server binary defaults to .build/debug/sws-bench (`swift build --product sws-bench`).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.build/debug/sws-bench"
TLS=0
REPORT=""
H2SPEC=${H2SPEC:-$(command -v h2spec || echo /opt/homebrew/bin/h2spec)}

while [ $# -gt 0 ]; do
  case "$1" in
    --tls) TLS=1; shift ;;
    --bin) BIN="$2"; shift 2 ;;
    --h2spec) H2SPEC="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "usage: $0 [--tls] [--bin PATH] [--h2spec PATH] [--report FILE] [-- h2spec args...]" >&2; exit 2 ;;
  esac
done

[ -x "$H2SPEC" ] || { echo "h2spec not found (brew install h2spec)" >&2; exit 3; }
[ -x "$BIN" ] || { echo "server binary not found: $BIN (swift build --product sws-bench)" >&2; exit 3; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/h2spec.XXXXXX")
SERVER_OUT="$TMP/server.out"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  [ -n "${WATCHDOG_PID:-}" ] && kill -KILL "$WATCHDOG_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

SERVER_ARGS=(serve --h2-only --host 127.0.0.1 --port 0 --drain-timeout 1)
H2SPEC_FLAGS=()
if [ "$TLS" = 1 ]; then
  SERVER_ARGS+=(--tls)
  H2SPEC_FLAGS+=(-t -k)
fi

cd "$ROOT"  # --tls reads .test-identity/server.p12 relative to the working directory
"$BIN" "${SERVER_ARGS[@]}" >"$SERVER_OUT" 2>&1 &
SERVER_PID=$!
# If this script is SIGKILLed (a test timeout), the trap does not run: a watchdog stops the
# server once this shell is gone, so no server outlives the run.
(
  trap '' TERM INT
  while kill -0 $$ 2>/dev/null; do sleep 1; done
  kill -KILL "$SERVER_PID" 2>/dev/null
) >/dev/null 2>&1 &
WATCHDOG_PID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT=$(sed -n 's/^listening .*:\([0-9][0-9]*\)$/\1/p' "$SERVER_OUT" | head -1)
  [ -n "$PORT" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "server did not start:" >&2
  cat "$SERVER_OUT" >&2
  exit 3
fi

if [ -n "$REPORT" ]; then
  "$H2SPEC" -h 127.0.0.1 -p "$PORT" ${H2SPEC_FLAGS[@]+"${H2SPEC_FLAGS[@]}"} "$@" 2>&1 | tee "$REPORT"
  STATUS=${PIPESTATUS[0]}
else
  "$H2SPEC" -h 127.0.0.1 -p "$PORT" ${H2SPEC_FLAGS[@]+"${H2SPEC_FLAGS[@]}"} "$@"
  STATUS=$?
fi
exit "$STATUS"
