#!/bin/bash
# New-connection (accept) throughput of the new server against nginx (#0113).
#
#   scripts/bench-accept.sh [rounds] [requests] [concurrency] [variant...]
#
# Each variant is NAME or NAME=SERVE_ARGS, for example
#   scripts/bench-accept.sh 3 10000 16 nw="--transport nw" bsd="--transport bsd"
# With no variant, one `sws` variant with the default `sws-bench serve` arguments is run.
#
# Every round runs `oha --disable-keepalive -n REQUESTS -c CONCURRENCY` against each variant
# and nginx, in that order, then the same rounds of the keep-alive case (`-z 5s -c CONCURRENCY`). REQUESTS defaults to 10,000, below the 16,384 ephemeral ports of the default
# macOS range, and the script waits for TIME_WAIT sockets to drain between runs, so the
# client never runs out of source ports (which is what made the closed-connection rows of
# docs/SERVER-COMPARISON.md noisy).
#
# Servers bind 127.0.0.1 on free ports, run as the current user, and are killed on exit.
# Run it through scripts/guarded.sh (AGENTS.md).

set -o pipefail
cd "$(dirname "$0")/.."
ROUNDS="${1:-3}"
N="${2:-10000}"
C="${3:-16}"
shift 3 2>/dev/null || shift $#
VARIANTS=("$@")
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=("sws")
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sws-accept.XXXXXX")"
PIDS=()

cleanup() {
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
  [ -f "$WORK/nginx.pid" ] && kill -TERM "$(cat "$WORK/nginx.pid")" 2>/dev/null
  sleep 1
  pkill -f "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
wait_port() { for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$1/index.html" && return 0; sleep 0.1; done; echo "server on $1 did not start" >&2; return 1; }
drain_time_wait() {
  for _ in $(seq 1 90); do
    [ "$(netstat -an -p tcp | grep -c TIME_WAIT)" -lt 500 ] && break
    sleep 1
  done
  sleep 1
}

swift build -c release -j 2 --product sws-bench > "$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; echo "build failed"; exit 1; }
SWS_BIN="$(swift build -c release --show-bin-path)/sws-bench"

NAMES=()
PORTS=()
for v in "${VARIANTS[@]}"; do
  name="${v%%=*}"
  args=""
  [[ "$v" == *=* ]] && args="${v#*=}"
  port=$(free_port)
  # shellcheck disable=SC2086
  "$SWS_BIN" serve --host 127.0.0.1 --port "$port" --body-size 626 $args > "$WORK/$name.log" 2>&1 &
  PIDS+=($!)
  NAMES+=("$name")
  PORTS+=("$port")
done

mkdir -p "$WORK/root" "$WORK/nginx-tmp"
cp Root/Public/index.html "$WORK/root/index.html"
NGINX_PORT=$(free_port)
cat > "$WORK/nginx.conf" <<EOF
worker_processes auto;
pid $WORK/nginx.pid;
error_log $WORK/nginx-error.log warn;
events { worker_connections 4096; }
http {
  access_log off;
  sendfile on;
  tcp_nopush on;
  keepalive_requests 1000000;
  open_file_cache max=1000;
  client_body_temp_path $WORK/nginx-tmp;
  proxy_temp_path $WORK/nginx-tmp;
  fastcgi_temp_path $WORK/nginx-tmp;
  uwsgi_temp_path $WORK/nginx-tmp;
  scgi_temp_path $WORK/nginx-tmp;
  types { text/html html; }
  server { listen 127.0.0.1:$NGINX_PORT; root $WORK/root; }
}
EOF
/opt/homebrew/bin/nginx -p "$WORK" -c "$WORK/nginx.conf" -g 'daemon off;' > "$WORK/nginx.out" 2>&1 &
PIDS+=($!)
NAMES+=("nginx")
PORTS+=("$NGINX_PORT")

for p in "${PORTS[@]}"; do wait_port "$p" || { tail -5 "$WORK"/*.log; exit 1; }; done
for p in "${PORTS[@]}"; do
  lsof -nP -iTCP:"$p" -sTCP:LISTEN | awk 'NR>1{print $9}' | grep -qv '^127\.0\.0\.1:' && { echo "port $p not loopback-only" >&2; exit 1; }
done

summarize() { # name mode round file
  python3 - "$@" <<'PY'
import json, sys
name, mode, rnd, path = sys.argv[1:]
d = json.load(open(path))
s = d["summary"]; p = d["latencyPercentiles"]
errs = sum(d.get("errorDistribution", {}).values())
ok = d.get("statusCodeDistribution", {}).get("200", 0)
print(f"| {name} | {mode} | {rnd} | {s['requestsPerSec']:,.0f} | {p['p50']*1000:.3f} | {p['p99']*1000:.3f} | {ok:,} | {errs} |")
PY
}

load() { uptime | sed 's/.*load averages*: //'; }
echo "load before: $(load)"
echo
echo "| Server | Mode | Round | req/s | p50 ms | p99 ms | 200s | errors |"
echo "|---|---|---:|---:|---:|---:|---:|---:|"
drain_time_wait
for r in $(seq 1 "$ROUNDS"); do
  for i in "${!NAMES[@]}"; do
    oha --no-tui --output-format json -n "$N" -c "$C" --disable-keepalive \
      "http://127.0.0.1:${PORTS[$i]}/index.html" > "$WORK/r.json" 2>/dev/null
    summarize "${NAMES[$i]}" close "$r" "$WORK/r.json"
    drain_time_wait
  done
done
for r in $(seq 1 "$ROUNDS"); do
  for i in "${!NAMES[@]}"; do
    oha --no-tui --output-format json -z 5s -c "$C" "http://127.0.0.1:${PORTS[$i]}/index.html" > "$WORK/r.json" 2>/dev/null
    summarize "${NAMES[$i]}" keepalive "$r" "$WORK/r.json"
  done
done
echo
echo "load after: $(load)"
