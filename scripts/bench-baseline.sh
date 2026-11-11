#!/bin/bash
# Records the M0 load baseline for the legacy SwiftWebServer.
#
#   scripts/bench-baseline.sh [output.md]      (default docs/benchmarks/M0-baseline.md)
#
# Builds release, serves a temporary copy of Root/Public (plus a generated large
# file) from the legacy server on a free port, and measures it with
# `sws-bench load`, cross-checked by oha. Caddy is measured on the same files as a
# reference when installed. Nothing is written under Root/.
#
# Everything binds and connects to 127.0.0.1 only, and every server and client
# runs under scripts/guarded.sh (timeout + system-prompt watchdog), per AGENTS.md.
#
# Environment: DURATION (seconds per run, default 10), CONNECTIONS (default 16),
# LARGE_MB (large file size, default 8), OHA, CADDY (tool paths), SKIP_CADDY=1.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
OUT=${1:-docs/benchmarks/M0-baseline.md}
DURATION=${DURATION:-10}
CONNECTIONS=${CONNECTIONS:-16}
LARGE_MB=${LARGE_MB:-8}
OHA=${OHA:-/opt/homebrew/bin/oha}
CADDY=${CADDY:-/opt/homebrew/bin/caddy}
PYTHON=${PYTHON:-/usr/bin/python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sws-bench.XXXXXX")
RESULTS=$WORK/results
mkdir -p "$RESULTS"
GUARD=$REPO/scripts/guarded.sh
PIDS=()
# Stops a server started under guarded.sh: its child (the server) first, then the guard.
stop_server() {
    local guard=$1
    pkill -TERM -P "$guard" 2>/dev/null || true
    kill -TERM "$guard" 2>/dev/null || true
}
cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && stop_server "$pid"
    done
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

free_port() {
    "$PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

wait_for_port() {
    local port=$1
    for _ in $(seq 1 100); do
        if curl -s -o /dev/null "http://127.0.0.1:$port/"; then return 0; fi
        sleep 0.1
    done
    echo "server on port $port did not start" >&2
    return 1
}

# Refuses to continue unless the only listener on the port is loopback.
check_loopback_only() {
    local port=$1 listeners
    listeners=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u)
    if [ -z "$listeners" ] || echo "$listeners" | grep -qv -E '^(127\.0\.0\.1|\[::1\]):'; then
        echo "listener on port $port is not loopback-only: ${listeners:-none}" >&2
        return 1
    fi
}

# Close-mode runs leave one TIME_WAIT socket per request, and on loopback those pin
# ephemeral ports (16k by default, held 2 x MSL = 30 s). Wait for them to drain before
# the next run so one run cannot starve the next of ports.
wait_for_time_wait_drain() {
    for _ in $(seq 1 90); do
        [ "$(netstat -an -p tcp 2>/dev/null | grep -c TIME_WAIT)" -lt 500 ] && return 0
        sleep 1
    done
}

# Upper bound for one server's lifetime: every run plus slack.
SERVER_BUDGET=$(( (DURATION + 100) * 6 + 120 ))
CLIENT_BUDGET=$(( DURATION + 30 ))
wait_for_time_wait_drain

echo "==> swift build -c release"
swift build -c release 2>&1 | tail -1
swift build -c release --product sws-bench 2>&1 | tail -1
BIN=$(swift build -c release --show-bin-path)

# Fixture: the legacy server reads its port from http-config.json under ROOT_PATH,
# so serve a temporary root whose config points at a free port. Public is a copy
# of Root/Public plus the generated large file, so the repository stays untouched.
cp -R "$REPO/Root/Public" "$WORK/Public"
dd if=/dev/urandom of="$WORK/Public/large.bin" bs=1048576 count="$LARGE_MB" 2>/dev/null
LARGE_BYTES=$(stat -f %z "$WORK/Public/large.bin")
SMALL_BYTES=$(stat -f %z "$WORK/Public/index.html")

# The legacy server degrades as it runs (it leaks per-connection tasks and memory), so
# every legacy measurement gets a fresh process; its RSS afterwards is recorded.
LEGACY_GUARD=""
start_legacy() {
    LEGACY_PORT=$(free_port)
    sed -E "s/\"port\": *[0-9]+/\"port\": $LEGACY_PORT/" "$REPO/Root/http-config.json" > "$WORK/http-config.json"
    "$GUARD" -t "$SERVER_BUDGET" -- env ROOT_PATH="$WORK" LISTEN_HOST=127.0.0.1 "$BIN/SwiftWebServer" \
        >>"$WORK/legacy.log" 2>&1 &
    LEGACY_GUARD=$!
    PIDS+=("$LEGACY_GUARD")
    wait_for_port "$LEGACY_PORT"
    check_loopback_only "$LEGACY_PORT"
}

# run_client NAME CLIENT(sws|oha) PORT PATH KEEPALIVE(on|off)
run_client() {
    local name=$1 client=$2 port=$3 path=$4 keepalive=$5
    echo "==> $name: $client $path (keep-alive $keepalive)"
    if [ "$client" = sws ]; then
        local flag=--keepalive
        [ "$keepalive" = off ] && flag=--no-keepalive
        "$GUARD" -t "$CLIENT_BUDGET" -- "$BIN/sws-bench" load --url "http://127.0.0.1:$port$path" \
            --connections "$CONNECTIONS" --duration "$DURATION" "$flag" --json > "$RESULTS/$name.sws.json" || true
    else
        local oha_flag=()
        [ "$keepalive" = off ] && oha_flag=(--disable-keepalive)
        "$GUARD" -t "$CLIENT_BUDGET" -- "$OHA" -z "${DURATION}s" -c "$CONNECTIONS" --no-tui --output-format json \
            ${oha_flag[@]+"${oha_flag[@]}"} "http://127.0.0.1:$port$path" > "$RESULTS/$name.oha.json" || true
    fi
    wait_for_time_wait_drain
}

# legacy_case NAME PATH: each client against its own fresh legacy server.
legacy_case() {
    local name=$1 path=$2 client pid
    for client in sws oha; do
        start_legacy
        echo "    legacy SwiftWebServer on 127.0.0.1:$LEGACY_PORT"
        run_client "$name" "$client" "$LEGACY_PORT" "$path" off
        pid=$(pgrep -P "$LEGACY_GUARD" | head -1 || true)
        ps -o rss= -p "${pid:-0}" 2>/dev/null | tr -d ' ' > "$RESULTS/$name.$client.rss" || true
        stop_server "$LEGACY_GUARD"
        sleep 1
    done
}

legacy_case legacy-small /
legacy_case legacy-large /large.bin

if [ "${SKIP_CADDY:-0}" != 1 ] && [ -x "$CADDY" ]; then
    CADDY_PORT=$(free_port)
    echo "==> caddy file-server on 127.0.0.1:$CADDY_PORT"
    # --listen with an explicit loopback address (plain HTTP, no automatic HTTPS).
    "$GUARD" -t "$SERVER_BUDGET" -- "$CADDY" file-server --root "$WORK/Public" \
        --listen "127.0.0.1:$CADDY_PORT" >"$WORK/caddy.log" 2>&1 &
    CADDY_GUARD=$!
    PIDS+=("$CADDY_GUARD")
    wait_for_port "$CADDY_PORT"
    check_loopback_only "$CADDY_PORT"
    for client in sws oha; do
        run_client caddy-small "$client" "$CADDY_PORT" / off
        run_client caddy-large "$client" "$CADDY_PORT" /large.bin off
        run_client caddy-small-keepalive "$client" "$CADDY_PORT" / on
    done
    stop_server "$CADDY_GUARD"
    CADDY_VERSION=$("$CADDY" version | cut -d' ' -f1)
else
    CADDY_VERSION=""
fi

mkdir -p "$(dirname "$OUT")"
export RESULTS OUT DURATION CONNECTIONS LARGE_MB LARGE_BYTES SMALL_BYTES CADDY_VERSION
export PORT_RANGE="$(sysctl -n net.inet.ip.portrange.first)-$(sysctl -n net.inet.ip.portrange.last), MSL $(sysctl -n net.inet.tcp.msl) ms"
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
import json, os

R = os.environ["RESULTS"]
env = os.environ

def load(name):
    try:
        with open(os.path.join(R, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def sws_row(case, label):
    d = load(f"{case}.sws.json")
    if not d:
        return f"| {label} | sws-bench | failed | | | | |"
    r = d["result"]
    lat = r.get("latencyMilliseconds") or {}
    errs = ", ".join(f"{k} {v}" for k, v in sorted(r["errorsByKind"].items())) or "0"
    return (f"| {label} | sws-bench | {r['requestsPerSecond']:,.0f} | {lat.get('p50', 0):.3f} | "
            f"{lat.get('p99', 0):.3f} | {r['bodyMegabytesPerSecond']:,.1f} | {errs} |")

def oha_row(case, label):
    d = load(f"{case}.oha.json")
    if not d:
        return f"| {label} | oha | failed | | | | |"
    s, p = d["summary"], d["latencyPercentiles"]
    # oha counts in-flight requests cut off at the deadline as errors; report them separately.
    errs = {k: v for k, v in (d.get("errorDistribution") or {}).items()}
    deadline = errs.pop("aborted due to deadline", 0)
    text = ", ".join(f"{k} {v}" for k, v in sorted(errs.items())) or "0"
    if deadline:
        text += f" (+{deadline} cut at deadline)"
    mib = (s.get("sizePerSec") or 0) / 1048576
    return (f"| {label} | oha | {s['requestsPerSec']:,.0f} | {p['p50'] * 1000:.3f} | "
            f"{p['p99'] * 1000:.3f} | {mib:,.1f} | {text} |")

small = int(env["SMALL_BYTES"])
large_mb = env["LARGE_MB"]
cases = [("legacy-small", f"legacy `/` ({small} B), close"),
         ("legacy-large", f"legacy `/large.bin` ({large_mb} MiB), close")]
reference = []
if env.get("CADDY_VERSION"):
    reference = [("caddy-small", f"caddy `/` ({small} B), close"),
                 ("caddy-large", f"caddy `/large.bin` ({large_mb} MiB), close"),
                 ("caddy-small-keepalive", f"caddy `/` ({small} B), keep-alive")]

def rss_text():
    parts = []
    for case, label in cases:
        for client, name in (("sws", "sws-bench"), ("oha", "oha")):
            try:
                with open(os.path.join(R, f"{case}.{client}.rss")) as f:
                    kb = int(f.read().strip())
                parts.append(f"{label} / {name}: {kb // 1024} MiB")
            except (OSError, ValueError):
                pass
    return "; ".join(parts) or "n/a"

def load_warning():
    try:
        one_minute = float(env["LOAD_AVERAGE"].split()[0])
    except (ValueError, IndexError):
        return ""
    cores = int(env["CORES"])
    if one_minute <= cores:
        return ""
    return (f"\n> **Provisional: recorded on a loaded machine** (1-minute load average {one_minute:.0f} on "
            f"{cores} cores, from other work running in parallel). These numbers are depressed and noisy. "
            f"Re-run `scripts/bench-baseline.sh` on an idle machine before using them as a gate.\n")

def table(rows):
    out = ["| Case | Client | req/s | p50 ms | p99 ms | body MiB/s | errors |",
           "|---|---|---:|---:|---:|---:|---|"]
    for case, label in rows:
        out.append(sws_row(case, label))
        out.append(oha_row(case, label))
    return "\n".join(out)

doc = f"""# M0 baseline: legacy SwiftWebServer

Recorded by `scripts/bench-baseline.sh` on {env['DATE']} at commit `{env['COMMIT']}`.
This is the reference that later milestones compare against (see [README](README.md)).
{load_warning()}
## Machine

| | |
|---|---|
| CPU | {env['CPU']} ({env['CORES']} cores) |
| Memory | {env['MEMORY_GB']} GB |
| OS | {env['OS_VERSION']} |
| Swift | {env['SWIFT_VERSION']} |
| Build | `swift build -c release` |
| Load tools | `sws-bench load`, {env['OHA_VERSION']} |
| Ephemeral ports | {env['PORT_RANGE']} |
| Load average at end | {env['LOAD_AVERAGE']} (1, 5, 15 min) |

## Method

- Server: the legacy `SwiftWebServer` release binary, `ROOT_PATH` pointing at a temporary
  root whose `http-config.json` is `Root/http-config.json` with a free port, serving a copy
  of `Root/Public` plus a generated {large_mb} MiB random `large.bin`. `LISTEN_HOST=127.0.0.1`
  keeps it on loopback. Each client run gets a fresh server process, because the legacy
  server slows down and grows as it serves (unbounded per-connection streams and tasks).
- Each run: {env['CONNECTIONS']} connections, {env['DURATION']} s, client and server on the same
  machine over loopback. `sws-bench load` then `oha` against the same URL.
- The legacy server closes the connection after every response, so it is measured with
  keep-alive off (`--no-keepalive`, `oha --disable-keepalive`); latency then includes the
  TCP connect.
- Latency is request start to last response byte. `sws-bench` p50/p99 interpolate between
  ranks; oha reports its own percentiles.

## Legacy server

{table(cases)}

Legacy server RSS after each run (fresh process per run): {rss_text()}.
"""
if reference:
    doc += f"""
## Reference: Caddy {env['CADDY_VERSION']}

`caddy file-server` on the same files, for scale only. Not a gate.

{table(reference)}
"""
doc += """
## Notes

- `sws-bench load` opens connections through Network.framework (`NWConnection`), whose
  per-connection setup is far more expensive than oha's raw sockets. With keep-alive off the
  client itself caps throughput; the Caddy close rows show that ceiling. When a close-mode
  server number approaches it, oha's figure is the one that measures the server.
  With keep-alive on, the two clients are much closer.
- Close-mode load is limited by ephemeral ports: every request leaves a loopback TIME_WAIT
  socket for 2 x MSL, so above about 16k / 30 s = 550 new connections per second sustained,
  a run of more than a few seconds starts failing connects (oha: "Can't assign requested
  address"; sws-bench: `connect` errors). The script waits for TIME_WAIT to drain between
  runs, but a fast server in close mode (the Caddy close rows) still hits the limit within
  one run. Keep-alive numbers do not have this problem.
- Other work on the machine shows in the load average above; a loaded machine depresses
  every number. Compare runs only at similar load.
- oha reports requests in flight at the deadline as errors ("cut at deadline"); they are
  listed separately and are not failures.
- Compare a server only against numbers taken with the same client, case and settings.
- Re-run with `scripts/bench-baseline.sh`; set `DURATION`, `CONNECTIONS`, `LARGE_MB` to change
  the load. Raw JSON is written to a temporary directory and discarded.
"""
with open(env["OUT"], "w") as f:
    f.write(doc)
print(f"wrote {env['OUT']}")
PY
