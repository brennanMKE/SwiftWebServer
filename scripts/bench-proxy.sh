#!/bin/bash
# Reverse-proxy overhead (#0124): keep-alive hello-world throughput and latency through
# SwiftWebServer's `proxy`, Apache mod_proxy and nginx proxy_pass, against the same upstream,
# compared with hitting the upstream directly.
#
#   scripts/bench-proxy.sh [duration_seconds] [concurrency levels...]
#   scripts/bench-proxy.sh 5 1 16 64
#
# The upstream is `sws-bench serve` (built-in hello handler, 14-byte body). Every server binds
# 127.0.0.1 on a free high port, runs as the current user with configs under $TMPDIR, and is
# killed on exit. No sudo, no system config touched. Load is oha (HTTP/1.1 keep-alive).
# Prints one markdown table row per run, with `uptime` load averages before and after and the
# sockets to the upstream left in TIME_WAIT (connection churn: an upstream pool too small).

set -o pipefail
cd "$(dirname "$0")/.."
DUR="${1:-5}"
shift || true
LEVELS=("${@:-1 16 64}")
[ $# -eq 0 ] && LEVELS=(1 16 64)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sws-bench-proxy.XXXXXX")"
PIDS=()

cleanup() {
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  [ -f "$WORK/nginx.pid" ] && kill -TERM "$(cat "$WORK/nginx.pid" 2>/dev/null)" 2>/dev/null
  [ -f "$WORK/httpd.pid" ] && kill -TERM "$(cat "$WORK/httpd.pid" 2>/dev/null)" 2>/dev/null
  sleep 1
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
  pkill -f "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
wait_port() {
  for _ in $(seq 1 100); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/")" = 200 ] && return 0
    sleep 0.1
  done
  echo "server on $1 did not answer 200" >&2; return 1
}
load() { uptime | sed 's/.*load averages*: //'; }
time_wait() { netstat -an -p tcp | grep TIME_WAIT | grep -c "${1:-}"; }
# A run that churns connections leaves sockets in TIME_WAIT (30 s on macOS) and can exhaust
# the 16k ephemeral ports for the next run; wait for them to drain first.
drain() { for _ in $(seq 1 40); do [ "$(time_wait)" -lt 2000 ] && return; sleep 1; done; }

mkdir -p "$WORK/logs" "$WORK/root" "$WORK/nginx-tmp"

swift build -c release -j 2 --product sws-bench > /dev/null 2>&1 || { echo "sws-bench build failed"; exit 1; }
swift build -c release -j 2 --product SwiftWebServer > /dev/null 2>&1 || { echo "SwiftWebServer build failed"; exit 1; }
BIN="$(swift build -c release --show-bin-path)"

# --- upstream: sws-bench serve (hello) ---
UP=$(free_port)
"$BIN/sws-bench" serve --host 127.0.0.1 --port "$UP" > "$WORK/logs/upstream.log" 2>&1 &
PIDS+=($!)

# --- SwiftWebServer proxy ---
SWS=$(free_port)
cat > "$WORK/sws.json" <<EOF
{
  "host": "127.0.0.1",
  "port": $SWS,
  "root": "$WORK/root",
  "proxy": [{ "path": "/", "upstream": "http://127.0.0.1:$UP",
              "pool": { "maxIdle": 512 } }]
}
EOF
"$BIN/SwiftWebServer" --config "$WORK/sws.json" > "$WORK/logs/sws.log" 2>&1 &
PIDS+=($!)

# --- nginx proxy_pass with an upstream keepalive pool ---
NGINX=$(free_port)
cat > "$WORK/nginx.conf" <<EOF
worker_processes auto;
pid $WORK/nginx.pid;
error_log $WORK/logs/nginx-error.log warn;
events { worker_connections 4096; }
http {
  access_log off;
  keepalive_requests 1000000;
  client_body_temp_path $WORK/nginx-tmp;
  proxy_temp_path $WORK/nginx-tmp;
  fastcgi_temp_path $WORK/nginx-tmp;
  uwsgi_temp_path $WORK/nginx-tmp;
  scgi_temp_path $WORK/nginx-tmp;
  upstream app { server 127.0.0.1:$UP; keepalive 512; keepalive_requests 1000000; }
  server {
    listen 127.0.0.1:$NGINX;
    location / {
      proxy_pass http://app;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$remote_addr;
      proxy_set_header X-Forwarded-Proto \$scheme;
    }
  }
}
EOF
/opt/homebrew/bin/nginx -p "$WORK" -c "$WORK/nginx.conf" -g 'daemon off;' > "$WORK/logs/nginx.out" 2>&1 &
PIDS+=($!)

# --- Apache httpd mod_proxy (macOS /usr/sbin/httpd, event MPM) ---
HTTPD=$(free_port)
M=/usr/libexec/apache2
cat > "$WORK/httpd.conf" <<EOF
ServerRoot "$WORK"
Listen 127.0.0.1:$HTTPD
PidFile "$WORK/httpd.pid"
DefaultRuntimeDir "$WORK"
Mutex file:$WORK default
ErrorLog "$WORK/logs/httpd-error.log"
LoadModule mpm_event_module $M/mod_mpm_event.so
LoadModule authz_core_module $M/mod_authz_core.so
LoadModule unixd_module $M/mod_unixd.so
LoadModule proxy_module $M/mod_proxy.so
LoadModule proxy_http_module $M/mod_proxy_http.so
ServerName 127.0.0.1
DocumentRoot "$WORK/root"
KeepAlive On
MaxKeepAliveRequests 0
KeepAliveTimeout 30
ServerLimit 16
ThreadsPerChild 64
MaxRequestWorkers 1024
ProxyPass "/" "http://127.0.0.1:$UP/" keepalive=On
ProxyPassReverse "/" "http://127.0.0.1:$UP/"
EOF
/usr/sbin/httpd -f "$WORK/httpd.conf" -DFOREGROUND > "$WORK/logs/httpd.out" 2>&1 &
PIDS+=($!)

for port in $UP $SWS $NGINX $HTTPD; do wait_port "$port" || { cat "$WORK"/logs/*; exit 1; }; done
for port in $SWS $NGINX $HTTPD; do
  body=$(curl -s "http://127.0.0.1:$port/")
  [ "$body" = "Hello, World!" ] || { echo "port $port answered: $body" >&2; exit 1; }
done

echo "| target | c | req/s | p50 ms | p99 ms | errors | upstream TIME_WAIT | load before | load after |"
echo "|---|---:|---:|---:|---:|---:|---:|---|---|"
for c in "${LEVELS[@]}"; do
  for target in direct:$UP sws:$SWS apache:$HTTPD nginx:$NGINX; do
    name=${target%%:*}; port=${target##*:}
    # Warm the pools, then measure.
    drain
    oha --no-tui -z 1s -c "$c" --output-format quiet "http://127.0.0.1:$port/" > /dev/null 2>&1
    before=$(load)
    oha --no-tui -z "${DUR}s" -c "$c" --output-format json "http://127.0.0.1:$port/" > "$WORK/oha.json" 2>/dev/null
    after=$(load)
    churn=$(time_wait "127.0.0.1.$UP ")
    python3 -I - "$WORK/oha.json" "$name" "$c" "$before" "$after" "$churn" <<'PY'
import json, sys
path, name, c, before, after, churn = sys.argv[1:]
d = json.load(open(path))
s = d["summary"]
p = d.get("latencyPercentiles", {})
codes = d.get("statusCodeDistribution", {})
non200 = sum(v for k, v in codes.items() if k != "200")
# oha counts the requests still in flight at the deadline as errors; those are not failures.
failed = {k: v for k, v in d.get("errorDistribution", {}).items() if k != "aborted due to deadline"}
errors = sum(failed.values()) + non200
if errors:
    print(f"{name} c={c}: {failed} {codes}", file=sys.stderr)
print(f"| {name} | {c} | {s['requestsPerSec']:,.0f} | {p['p50']*1000:.3f} | {p['p99']*1000:.3f} | {errors} | {churn} | {before} | {after} |")
PY
  done
done
