#!/usr/bin/env bash
# Deploy a System 1 decision server to another Mac on your tailnet:
# SwiftWebServer listens on the Mac's Tailscale address and reverse-proxies
# /laya to laya-server (Laya on the GPU via Metal) on that Mac's loopback.
#
#   Examples/parallax-gordon/deploy.sh            # build, ship, (re)start, check
#   Examples/parallax-gordon/deploy.sh --check    # only check what's running
#   Examples/parallax-gordon/deploy.sh --stop     # stop both services
#
# Settings (environment):
#   SYSTEM1_SSH        ssh destination of the server Mac   (default: gordon)
#   SYSTEM1_DIR        install folder on that Mac          (default: ~/Services/system1)
#   SYSTEM1_PORT       loopback port SwiftWebServer listens on (default: 8080)
#   SYSTEM1_PUBLIC_PORT  tailnet port Tailscale forwards to it (default: 80)
#   SYSTEM1_DECISION_PORT  loopback port of the laya-swift decisions server (default: 8790)
#   SYSTEM1_LAYA_PORT  laya-server's loopback port there   (default: 8799)
#   SYSTEM1_BIND       address SwiftWebServer binds (default: 127.0.0.1). macOS lets
#                      a non-root process bind a port below 1024 only on 0.0.0.0, so
#                      `tailscale serve --tcp` forwards the tailnet's port 80 to it
#   LAYA_GO            laya-go checkout to build laya-server from
#                      (default: ../laya-go next to this repo)
#   LAYA_SWIFT         laya-swift checkout to build the /decision server from
#                      (default: ../laya-swift next to this repo)
#   SYSTEM1_KEY_FILE   the shared bearer key, created if missing
#                      (default: ~/.config/parallax-gordon/system1-key)
#
# Only the key's SHA-256 is sent to the server. Everything installs under
# SYSTEM1_DIR and three user LaunchAgents; nothing needs sudo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SSH_DEST="${SYSTEM1_SSH:-gordon}"
REMOTE_DIR="${SYSTEM1_DIR:-Services/system1}"   # relative to the remote home
PORT="${SYSTEM1_PORT:-8080}"
PUBLIC_PORT="${SYSTEM1_PUBLIC_PORT:-80}"
LAYA_PORT="${SYSTEM1_LAYA_PORT:-8799}"
DECISION_PORT="${SYSTEM1_DECISION_PORT:-8790}"
LAYA_GO="${LAYA_GO:-$REPO/../laya-go}"
LAYA_SWIFT="${LAYA_SWIFT:-$REPO/../laya-swift}"
KEY_FILE="${SYSTEM1_KEY_FILE:-$HOME/.config/parallax-gordon/system1-key}"
LABEL_PREFIX="com.github.swiftwebserver.system1"
TAILSCALE_CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_DEST" "$@"; }

remote_home="$(remote 'echo $HOME')"
DIR="$remote_home/${REMOTE_DIR#\~/}"
uid="$(remote 'id -u')"

bind_addr="${SYSTEM1_BIND:-127.0.0.1}"
ts_ip="$(remote "command -v tailscale >/dev/null && tailscale ip -4 || $TAILSCALE_CLI ip -4" | head -1)"
[[ -n "$ts_ip" ]] || { echo "Couldn't find the Tailscale address of $SSH_DEST." >&2; exit 1; }
if [[ "$PUBLIC_PORT" == 80 ]]; then base_url="http://$ts_ip"; else base_url="http://$ts_ip:$PUBLIC_PORT"; fi
ts_serve() { remote "TS=\$(command -v tailscale || echo $TAILSCALE_CLI); \$TS serve --bg --tcp $PUBLIC_PORT tcp://$bind_addr:$PORT >/dev/null && \$TS serve status | grep -A1 ':$PUBLIC_PORT' | head -2"; }

check() {
  echo "== $SSH_DEST ($base_url)"
  remote "launchctl print gui/$uid/$LABEL_PREFIX.laya 2>/dev/null | grep -E '^\s+(state|pid) =' | sed 's/^/laya:  /'; \
          launchctl print gui/$uid/$LABEL_PREFIX.decision 2>/dev/null | grep -E '^\s+(state|pid) =' | sed 's/^/decision: /'; \
          launchctl print gui/$uid/$LABEL_PREFIX.proxy 2>/dev/null | grep -E '^\s+(state|pid) =' | sed 's/^/proxy: /'" || true
  printf 'GET /             -> '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "$base_url/" || echo unreachable
  printf 'GET /laya/health  -> '; curl -s --max-time 5 "$base_url/laya/health" || echo unreachable; echo
  printf 'GET /decision/health -> '; curl -s --max-time 5 "$base_url/decision/health" || echo unreachable; echo
  printf 'GET /laya/stats   -> '
  curl -s --max-time 5 -H "Authorization: Bearer $(cat "$KEY_FILE")" "$base_url/laya/stats" | head -c 300 || echo unreachable
  echo
}

stop() {
  remote "launchctl bootout gui/$uid/$LABEL_PREFIX.proxy 2>/dev/null; launchctl bootout gui/$uid/$LABEL_PREFIX.laya 2>/dev/null; launchctl bootout gui/$uid/$LABEL_PREFIX.decision 2>/dev/null; true"
  echo "Stopped all three services on $SSH_DEST."
}

case "${1:-}" in
  --check) check; exit 0 ;;
  --stop) stop; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--check|--stop]" >&2; exit 2 ;;
esac

# The shared key: Parallax sends it as a bearer token, SwiftWebServer checks its hash.
if [[ ! -s "$KEY_FILE" ]]; then
  mkdir -p "$(dirname "$KEY_FILE")" && chmod 700 "$(dirname "$KEY_FILE")"
  (umask 077 && openssl rand -hex 32 | tr -d '\n' > "$KEY_FILE")
  echo "Created a new key in $KEY_FILE"
fi
token_sha="$(printf %s "$(cat "$KEY_FILE")" | shasum -a 256 | cut -d' ' -f1)"

# Build both binaries here (arm64 macOS), then ship them.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
echo "Building SwiftWebServer (release)…"
(cd "$REPO" && swift build -c release -j 2 --product SwiftWebServer >/dev/null)
echo "Building laya-server from ${LAYA_GO}…"
(cd "$LAYA_GO" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "$stage/bin/laya-server" ./cmd/laya-server)
echo "Building laya-swift (release) from ${LAYA_SWIFT}…"
(cd "$LAYA_SWIFT" && swift build -c release -j 2 --arch arm64 --product laya-swift >/dev/null \
   && cp "$(swift build -c release --arch arm64 --show-bin-path)/laya-swift" "$stage/bin/")
cp "$REPO/.build/release/SwiftWebServer" "$stage/bin/"
cp -R "$HERE/Public" "$stage/"
sed -e "s|@BIND_ADDR@|$bind_addr|" -e "s|@PORT@|$PORT|" -e "s|@LAYA_PORT@|$LAYA_PORT|" -e "s|@DECISION_PORT@|$DECISION_PORT|" \
    -e "s|@TOKEN_SHA256@|$token_sha|" "$HERE/http-config.template.json" > "$stage/http-config.json"
mkdir -p "$stage/launchd"
for svc in laya decision proxy; do
  sed -e "s|@DIR@|$DIR|g" -e "s|@LAYA_PORT@|$LAYA_PORT|g" -e "s|@DECISION_PORT@|$DECISION_PORT|g" -e "s|@LABEL_PREFIX@|$LABEL_PREFIX|g" \
      "$HERE/launchd/$svc.plist.template" > "$stage/launchd/$LABEL_PREFIX.$svc.plist"
done

echo "Shipping to $SSH_DEST:${DIR}…"
remote "mkdir -p '$DIR/logs' ~/Library/LaunchAgents"
rsync -a --delete --exclude logs "$stage/" "$SSH_DEST:$DIR/"

echo "Restarting the LaunchAgents…"
remote "set -e
  for svc in laya decision proxy; do
    plist=~/Library/LaunchAgents/$LABEL_PREFIX.\$svc.plist
    cp '$DIR/launchd/$LABEL_PREFIX.'\$svc.plist \"\$plist\"
    launchctl bootout gui/$uid/$LABEL_PREFIX.\$svc 2>/dev/null || true
    # bootout returns before the job is gone; bootstrap fails with error 5 until it is.
    for i in \$(seq 50); do launchctl print gui/$uid/$LABEL_PREFIX.\$svc >/dev/null 2>&1 || break; sleep 0.2; done
    for i in 1 2 3 4 5; do launchctl bootstrap gui/$uid \"\$plist\" 2>/dev/null && break; sleep 1; done
    launchctl print gui/$uid/$LABEL_PREFIX.\$svc >/dev/null
  done"

echo "Forwarding tailnet port $PUBLIC_PORT to $bind_addr:$PORT with tailscale serve…"
ts_serve

# laya-server loads (and on first run downloads, ~843 MB) the model before it listens.
echo "Waiting for Laya to answer (first run downloads the model)…"
for _ in $(seq 120); do
  curl -fs --max-time 2 "$base_url/laya/health" >/dev/null && break
  sleep 5
done
for _ in $(seq 24); do curl -fs --max-time 2 "$base_url/decision/health" >/dev/null && break; sleep 5; done
check
