#!/bin/bash
# Load benchmark of the shipped SwiftWebServer, compared with the M0 legacy baseline.
#
#   scripts/bench-baseline.sh [output.md]      (default docs/benchmarks/M4-cutover.md)
#
# The M0 baseline (docs/benchmarks/M0-baseline.md) was recorded by an earlier version of
# this script against the legacy server, which was deleted at the M4 cut-over (#0086). That
# record stays the reference; this script measures the current server with the same files,
# clients and settings, and adds keep-alive rows and a large-download memory check.
#
# Builds release, serves a temporary copy of Root/Public (plus a generated large file) with
# the release SwiftWebServer on a free loopback port, and measures it with `sws-bench load`
# and oha, keep-alive off (as in M0) and on. Then downloads a sparse LARGE_GB GiB file once
# and samples the server's RSS while it streams. Nothing is written under Root/.
#
# Everything binds and connects to 127.0.0.1 only, and every server and client runs under
# scripts/guarded.sh (timeout + system-prompt watchdog), per AGENTS.md.
#
# Environment: DURATION (seconds per run, default 10), CONNECTIONS (default 16),
# LARGE_MB (load-test large file, default 8), LARGE_GB (download check, default 1),
# OHA (tool path).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
OUT=${1:-docs/benchmarks/M4-cutover.md}
DURATION=${DURATION:-10}
CONNECTIONS=${CONNECTIONS:-16}
LARGE_MB=${LARGE_MB:-8}
LARGE_GB=${LARGE_GB:-1}
OHA=${OHA:-/opt/homebrew/bin/oha}
PYTHON=${PYTHON:-/usr/bin/python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sws-bench.XXXXXX")
RESULTS=$WORK/results
mkdir -p "$RESULTS"
GUARD=$REPO/scripts/guarded.sh
SERVER_GUARD=""
# Stops the server started under guarded.sh: its child (the server) first, then the guard.
stop_server() {
    local guard=$1
    pkill -TERM -P "$guard" 2>/dev/null || true
    sleep 1
    kill -TERM "$guard" 2>/dev/null || true
}
cleanup() {
    [ -n "$SERVER_GUARD" ] && stop_server "$SERVER_GUARD"
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_for_time_wait_drain() {
    # Close-mode runs leave one TIME_WAIT socket per request; on loopback those pin
    # ephemeral ports for 2 x MSL. Let them drain so one run cannot starve the next.
    for _ in $(seq 1 90); do
        [ "$(netstat -an -p tcp 2>/dev/null | grep -c TIME_WAIT)" -lt 500 ] && return 0
        sleep 1
    done
}

check_loopback_only() {
    local port=$1 listeners
    listeners=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u)
    if [ -z "$listeners" ] || echo "$listeners" | grep -qv -E '^(127\.0\.0\.1|\[::1\]):'; then
        echo "listener on port $port is not loopback-only: ${listeners:-none}" >&2
        return 1
    fi
}

SERVER_BUDGET=$(( (DURATION + 100) * 8 + 300 ))
CLIENT_BUDGET=$(( DURATION + 30 ))
LOAD_BEFORE="$(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
wait_for_time_wait_drain

echo "==> swift build -c release"
swift build -c release -j 2 --product SwiftWebServer 2>&1 | tail -1
swift build -c release -j 2 --product sws-bench 2>&1 | tail -1
BIN=$(swift build -c release --show-bin-path)

cp -R "$REPO/Root/Public" "$WORK/Public"
dd if=/dev/urandom of="$WORK/Public/large.bin" bs=1048576 count="$LARGE_MB" 2>/dev/null
# Sparse: no disk space or write time, and the read path is the same.
dd if=/dev/zero of="$WORK/Public/huge.bin" bs=1048576 count=0 seek=$(( LARGE_GB * 1024 )) 2>/dev/null
LARGE_BYTES=$(stat -f %z "$WORK/Public/large.bin")
HUGE_BYTES=$(stat -f %z "$WORK/Public/huge.bin")
SMALL_BYTES=$(stat -f %z "$WORK/Public/index.html")
cat > "$WORK/http-config.json" <<EOF
{ "host": "127.0.0.1", "port": 0, "root": "Public" }
EOF

echo "==> SwiftWebServer"
"$GUARD" -t "$SERVER_BUDGET" -- "$BIN/SwiftWebServer" --config "$WORK/http-config.json" \
    >"$WORK/server.out" 2>"$WORK/server.err" &
SERVER_GUARD=$!
for _ in $(seq 1 100); do
    grep -q '^listening ' "$WORK/server.out" 2>/dev/null && break
    sleep 0.1
done
PORT=$(sed -n 's/^listening .*:\([0-9]*\)$/\1/p' "$WORK/server.out" | head -1)
[ -n "$PORT" ] || { cat "$WORK/server.err" >&2; exit 1; }
check_loopback_only "$PORT"
SERVER_PID=$(pgrep -P "$SERVER_GUARD" | head -1)
echo "    127.0.0.1:$PORT (pid $SERVER_PID)"

rss_kb() { ps -o rss= -p "$SERVER_PID" 2>/dev/null | tr -d ' '; }

# run_client NAME CLIENT(sws|oha) PATH KEEPALIVE(on|off)
run_client() {
    local name=$1 client=$2 path=$3 keepalive=$4
    echo "==> $name: $client $path (keep-alive $keepalive)"
    if [ "$client" = sws ]; then
        local flag=--keepalive
        [ "$keepalive" = off ] && flag=--no-keepalive
        "$GUARD" -t "$CLIENT_BUDGET" -- "$BIN/sws-bench" load --url "http://127.0.0.1:$PORT$path" \
            --connections "$CONNECTIONS" --duration "$DURATION" "$flag" --json > "$RESULTS/$name.sws.json" || true
    else
        local oha_flag=()
        [ "$keepalive" = off ] && oha_flag=(--disable-keepalive)
        "$GUARD" -t "$CLIENT_BUDGET" -- "$OHA" -z "${DURATION}s" -c "$CONNECTIONS" --no-tui --output-format json \
            ${oha_flag[@]+"${oha_flag[@]}"} "http://127.0.0.1:$PORT$path" > "$RESULTS/$name.oha.json" || true
    fi
    rss_kb > "$RESULTS/$name.$client.rss" || true
    wait_for_time_wait_drain
}

rss_kb > "$RESULTS/start.rss"
for client in sws oha; do
    run_client small-close "$client" / off
    run_client large-close "$client" /large.bin off
    run_client small-keepalive "$client" / on
    run_client large-keepalive "$client" /large.bin on
done

echo "==> ${LARGE_GB} GiB download, sampling RSS"
rss_kb > "$RESULTS/huge.before.rss"
"$GUARD" -t 300 -- curl -sS --limit-rate 256M -o /dev/null -w '%{http_code} %{size_download} %{time_total}' \
    "http://127.0.0.1:$PORT/huge.bin" > "$RESULTS/huge.curl" &
CURL_GUARD=$!
PEAK=0
while kill -0 "$CURL_GUARD" 2>/dev/null; do
    now=$(rss_kb || echo 0)
    [ "${now:-0}" -gt "$PEAK" ] && PEAK=$now
    sleep 0.05
done
wait "$CURL_GUARD" || true
echo "$PEAK" > "$RESULTS/huge.peak.rss"
rss_kb > "$RESULTS/huge.after.rss"

stop_server "$SERVER_GUARD"
SERVER_GUARD=""

mkdir -p "$(dirname "$OUT")"
export RESULTS OUT DURATION CONNECTIONS LARGE_MB LARGE_GB LARGE_BYTES HUGE_BYTES SMALL_BYTES LOAD_BEFORE
export M0="$REPO/docs/benchmarks/M0-baseline.md"
export LOAD_AVERAGE="$(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
export SWIFT_VERSION="$(swift --version 2>/dev/null | head -1)"
export OHA_VERSION="$("$OHA" --version)"
export OS_VERSION="$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
export CPU="$(sysctl -n machdep.cpu.brand_string)"
export CORES="$(sysctl -n hw.ncpu)"
export MEMORY_GB="$(( $(sysctl -n hw.memsize) / 1073741824 ))"
export COMMIT="$(git rev-parse --short HEAD)"
export DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

"$PYTHON" - <<'PY'
import json, os, re

R = os.environ["RESULTS"]
env = os.environ

def load(name):
    try:
        with open(os.path.join(R, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def text(name):
    try:
        with open(os.path.join(R, name)) as f:
            return f.read().strip()
    except OSError:
        return ""

def kb(name):
    try:
        return int(text(name))
    except ValueError:
        return None

# M0 legacy rows: (case, client) -> req/s, from the recorded baseline table.
m0 = {}
try:
    for line in open(env["M0"]):
        m = re.match(r"\| legacy `(/[^`]*)` .*, close \| (sws-bench|oha) \| ([\d,]+) \|", line)
        if m:
            case = "small-close" if m.group(1) == "/" else "large-close"
            m0[(case, m.group(2))] = float(m.group(3).replace(",", ""))
except OSError:
    pass

def versus(case, client, rps):
    base = m0.get((case, client))
    if not base:
        return ""
    return f"{base:,.0f} | {(rps - base) / base * 100:+,.0f}%"

def sws_row(case, label):
    d = load(f"{case}.sws.json")
    if not d:
        return f"| {label} | sws-bench | failed | | | | | | |"
    r = d["result"]
    lat = r.get("latencyMilliseconds") or {}
    errs = ", ".join(f"{k} {v}" for k, v in sorted(r["errorsByKind"].items())) or "0"
    rps = r["requestsPerSecond"]
    return (f"| {label} | sws-bench | {rps:,.0f} | {lat.get('p50', 0):.3f} | {lat.get('p99', 0):.3f} | "
            f"{r['bodyMegabytesPerSecond']:,.1f} | {errs} | {versus(case, 'sws-bench', rps) or ' | '} |")

def oha_row(case, label):
    d = load(f"{case}.oha.json")
    if not d:
        return f"| {label} | oha | failed | | | | | | |"
    s, p = d["summary"], d["latencyPercentiles"]
    errs = dict(d.get("errorDistribution") or {})
    deadline = errs.pop("aborted due to deadline", 0)
    etext = ", ".join(f"{k} {v}" for k, v in sorted(errs.items())) or "0"
    if deadline:
        etext += f" (+{deadline} cut at deadline)"
    mib = (s.get("sizePerSec") or 0) / 1048576
    rps = s["requestsPerSec"]
    return (f"| {label} | oha | {rps:,.0f} | {p['p50'] * 1000:.3f} | {p['p99'] * 1000:.3f} | "
            f"{mib:,.1f} | {etext} | {versus(case, 'oha', rps) or ' | '} |")

small = int(env["SMALL_BYTES"])
large_mb = env["LARGE_MB"]
cases = [("small-close", f"`/` ({small} B), close"),
         ("large-close", f"`/large.bin` ({large_mb} MiB), close"),
         ("small-keepalive", f"`/` ({small} B), keep-alive"),
         ("large-keepalive", f"`/large.bin` ({large_mb} MiB), keep-alive")]

rows = ["| Case | Client | req/s | p50 ms | p99 ms | body MiB/s | errors | M0 legacy req/s | change |",
        "|---|---|---:|---:|---:|---:|---|---:|---:|"]
for case, label in cases:
    rows.append(sws_row(case, label))
    rows.append(oha_row(case, label))

rss = []
for case, label in cases:
    for client, name in (("sws", "sws-bench"), ("oha", "oha")):
        value = kb(f"{case}.{client}.rss")
        if value is not None:
            rss.append(f"| after {label} / {name} | {value / 1024:.1f} |")

curl = text("huge.curl").split()
huge_gib = int(env["HUGE_BYTES"]) / 1073741824
if len(curl) == 3:
    code, size, seconds = curl[0], int(curl[1]), float(curl[2])
    download = (f"HTTP {code}, {size:,} bytes in {seconds:.2f} s "
                f"({size / 1048576 / seconds:,.0f} MiB/s)")
else:
    download = "failed"
def mib(name):
    value = kb(name)
    return f"{value / 1024:.1f} MiB" if value is not None else "n/a"

def load_warning():
    try:
        one_minute = float(env["LOAD_AVERAGE"].split()[0])
    except (ValueError, IndexError):
        return ""
    cores = int(env["CORES"])
    if one_minute <= cores / 2:
        return ""
    return (f"\n> **Recorded on a loaded machine** (1-minute load average {one_minute:.1f} on {cores} cores, "
            f"from other work running in parallel). Numbers are depressed and noisy; re-run "
            f"`scripts/bench-baseline.sh` on an idle machine before using them as a gate.\n")

doc = f"""# M4 cut-over: shipped SwiftWebServer load and memory

Recorded by `scripts/bench-baseline.sh` on {env['DATE']} at commit `{env['COMMIT']}`.
Compared with the M0 legacy baseline ([M0-baseline.md](M0-baseline.md)); the legacy server
itself was deleted in #0086.
{load_warning()}
## Machine

| | |
|---|---|
| CPU | {env['CPU']} ({env['CORES']} cores) |
| Memory | {env['MEMORY_GB']} GB |
| OS | {env['OS_VERSION']} |
| Swift | {env['SWIFT_VERSION']} |
| Build | `swift build -c release` |
| Load tools | `sws-bench load`, {env['OHA_VERSION']}, curl |
| Load average before / after | {env['LOAD_BEFORE']} / {env['LOAD_AVERAGE']} (1, 5, 15 min) |

## Method

- Server: the release `SwiftWebServer` with a config of only `host`, `port: 0` and `root`
  (every other setting at its default: BSD transport, HTTP/1.1, ErrorPages + StaticFiles,
  `maxConnections` 1024), serving a copy of `Root/Public` plus a {large_mb} MiB random
  `large.bin`, as in M0. One server process for the whole run.
- Each run: {env['CONNECTIONS']} connections, {env['DURATION']} s, loopback, `sws-bench load` then oha.
  The close rows match the M0 cases (the legacy server closed every connection); the
  keep-alive rows have no M0 equivalent.
- Memory: `curl --limit-rate 256M` downloads a sparse {huge_gib:.0f} GiB `huge.bin` once (a client slower than
  the server, so backpressure is exercised) while the server's RSS
  is sampled every 50 ms.

## Load

{chr(10).join(rows)}

## Memory

| Point | RSS MiB |
|---|---:|
| idle, before load | {kb('start.rss') / 1024 if kb('start.rss') else 0:.1f} |
{chr(10).join(rss)}

{huge_gib:.0f} GiB download: {download}. Server RSS before {mib('huge.before.rss')}, peak during
{mib('huge.peak.rss')}, after {mib('huge.after.rss')}.
"""
with open(env["OUT"], "w") as f:
    f.write(doc)
print(f"wrote {env['OUT']}")
PY
