#!/usr/bin/env bash
# Run Parallax on this Mac with its System 1 computer players answered by the
# decision server on another Mac (deploy.sh), over Tailscale.
#
#   Examples/parallax-gordon/play.sh          # then open http://localhost:8080
#
# Settings (environment): PARALLAX (checkout, default ../Parallax next to this
# repo), SYSTEM1_URL (default http://<gordon's Tailscale IP>/laya/predict),
# SYSTEM1_SSH (default gordon, used only to look up that IP) and
# SYSTEM1_KEY_FILE (default ~/.config/parallax-gordon/system1-key).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PARALLAX="${PARALLAX:-$REPO/../Parallax}"
KEY_FILE="${SYSTEM1_KEY_FILE:-$HOME/.config/parallax-gordon/system1-key}"

url="${SYSTEM1_URL:-}"
if [[ -z "$url" ]]; then
  ip="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${SYSTEM1_SSH:-gordon}" \
        'command -v tailscale >/dev/null && tailscale ip -4 || /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4' | head -1)"
  url="http://$ip/laya/predict"
fi
[[ -s "$KEY_FILE" ]] || { echo "No key at $KEY_FILE; run deploy.sh first." >&2; exit 1; }

echo "System 1 endpoint: $url"
printf 'Laya health: '; curl -s --max-time 5 "${url%/predict}/health" || echo "unreachable (computers will play Planner)"; echo

cd "$PARALLAX"
[[ -x bin/server ]] || make build
export PARALLAX_SYSTEM1_KEY="$(cat "$KEY_FILE")"
exec scripts/restart.sh -system1 "$url"
