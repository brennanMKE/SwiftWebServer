# Parallax with a System 1 server on another Mac

This example uses SwiftWebServer as a reverse proxy in front of a **System 1 decision model**. The model is
[Laya](https://huggingface.co/convaiinnovations/laya), served by laya-go's `laya-server`, which runs Laya on the
GPU with Metal. It runs on a Mac mini ("gordon"). The game is [Parallax](https://github.com/brennanMKE/Parallax),
which runs on a MacBook. Its computer players ask gordon for their decisions over [Tailscale](https://tailscale.com).

```
MacBook                                gordon (Mac mini M2), tailnet only
┌──────────────────────────┐           ┌───────────────────────────────────────────────┐
│ browser ─ Parallax       │  HTTP     │ SwiftWebServer  100.x.y.z:8080                │
│ (bin/server -system1 …)  │ ───────▶  │  /             static status page             │
│ Bearer <key>             │ Tailscale │  /laya/health  open                           │
└──────────────────────────┘           │  /laya/predict ─┐ bearer token checked (Auth) │
                                       │  /laya/stats   ─┤                             │
                                       │                 ▼ proxy, stripPrefix          │
                                       │ laya-server 127.0.0.1:8799 (Metal, Apple M2)  │
                                       └───────────────────────────────────────────────┘
```

On gordon, SwiftWebServer handles all of these:

- **Network:** it is the only process listening on the network, and only on gordon's Tailscale address.
  `laya-server` stays on loopback.
- **Bearer key:** it checks the shared key. Only the key's SHA-256 is stored on gordon; `laya-server` has no
  authentication of its own.
- **Proxying:** it strips `/laya` from the path and forwards the request.
- **Health checks:** it checks `laya-server`'s `/health` every 10 s.
- **Failures:** it answers 502 or 504 when Laya is down or slow. Parallax then plays its rule-based Planner for
  that turn.
- **Access log:** it writes a combined-format log of every request.

## Measured

These numbers come from Parallax's `cmd/sim`, run on the MacBook against gordon over Tailscale. It played a
three-player game (System 1 against two Greedy players):

```
System 1 agreed with the oracle on 2002 of 2002 questions (100.0%), 30 ms per decision.
```

- **Single request:** a request through the proxy took 131 ms for a new state and 5 ms for a cached one.
- **Model load:** `laya-server` loaded the model in 11.9 s and logged `engine: metal fp16 weights (Apple M2)`.
- **Memory:** about 510 MB for `laya-server` and about 9 MB for SwiftWebServer.

## Set up

You need:

- **On the MacBook:** this repo, [laya-go](https://github.com/brennanMKE/laya-go) and Parallax checked out side
  by side; Swift, Go and Node.js; and an ssh alias for gordon (`gordon` by default).
- **On gordon:** Tailscale, about 1 GB of free disk for the model, and a logged-in user session (the services
  are user LaunchAgents).

Deploy, from the MacBook:

```sh
Examples/parallax-gordon/deploy.sh          # build, ship, start, check
Examples/parallax-gordon/deploy.sh --check  # what's running
Examples/parallax-gordon/deploy.sh --stop   # stop both services
```

`deploy.sh` does the following:

1. **Key:** it creates a shared key in `~/.config/parallax-gordon/system1-key` (mode 600), if there isn't one.
2. **Build:** it builds the release `SwiftWebServer` and `laya-server` for arm64 macOS on the MacBook.
3. **Config:** it writes `http-config.json` from `http-config.template.json`, filling in gordon's Tailscale IPv4
   address, the ports and the key's hash.
4. **Ship:** it copies everything to `~/Services/system1` on gordon:
   - `bin/`
   - `Public/`
   - `http-config.json`
   - `launchd/`
   - `logs/`
5. **Start:** it installs and restarts two LaunchAgents, `com.github.swiftwebserver.system1.laya` and `….proxy`.
   They start at login and restart if they exit. Nothing needs `sudo`.
6. **Check:** it waits for `/laya/health`, then checks the status page, health and stats. The first start
   downloads the model (846 MB) into `~/.cache/huggingface` on gordon.

Settings come from environment variables:

| Variable | Default |
|---|---|
| `SYSTEM1_SSH` | `gordon` |
| `SYSTEM1_DIR` | `Services/system1` (in gordon's home folder) |
| `SYSTEM1_PORT` | `8080` |
| `SYSTEM1_LAYA_PORT` | `8799` |
| `SYSTEM1_BIND` | gordon's Tailscale address |
| `LAYA_GO` | `../laya-go` |
| `SYSTEM1_KEY_FILE` | `~/.config/parallax-gordon/system1-key` |

## Play

```sh
Examples/parallax-gordon/play.sh            # then open http://localhost:8080
```

`play.sh` looks up gordon's Tailscale address and checks `/laya/health`. Then it starts Parallax through its own
`scripts/restart.sh` with `-system1 http://<gordon>:8080/laya/predict` and the key in `PARALLAX_SYSTEM1_KEY`, so
the key never appears in the process list. In the lobby, add computer players: "System 1 model" is now the
default computer. To watch the model play, add three computers and tick **Watch only**.

To measure the model without a browser, run this in the Parallax checkout:

```sh
go run ./cmd/sim -q -players 3 -ai system1,greedy,greedy \
  -url http://<gordon's Tailscale IP>:8080/laya/predict -key "$(cat ~/.config/parallax-gordon/system1-key)"
```

## Try it with curl

```sh
U=http://<gordon's Tailscale IP>:8080/laya
K=$(cat ~/.config/parallax-gordon/system1-key)
curl $U/health                                   # {"ok": true}
curl -X POST $U/predict -d '{}' -w '%{http_code}\n'   # 401: no key
curl -H "Authorization: Bearer $K" -X POST $U/predict -d '{
  "state": "Our attack on D is a bad bet: it would probably lose.",
  "questions": {
    "attack": {"type": "choice", "instructions": "Is this attack a good bet or a bad bet?",
               "criteria": {"good": "a good bet", "bad": "a bad bet"}},
    "send":   {"type": "noul", "instructions": "Should we send the fleet?"}}}'
```

The response, measured on gordon:

```json
{"answers": {"attack": {"type": "choice", "choice": "bad", "probabilities": {"good": 0.0114, "bad": 0.9886},
  "confidence": 0.9103, "action": {"act_probability": 1.0}},
  "send": {"type": "noul", "noul": 0.1374, "confidence": 0.8626, "action": {"act_probability": 1.0}}}}
```

`GET $U/stats` with the key shows Laya's answer cache: hits, misses and model calls.

## Logs

On gordon, in `~/Services/system1/logs/`:

| File | What's in it |
|---|---|
| `access.log` | One combined-format line per request, as SwiftWebServer finished it (proxied, 401 and so on). |
| `server.log` | SwiftWebServer's own output. |
| `laya.log` | Model download and load, the engine in use, and errors. |

## Notes

- **Why bind to the Tailscale address.** Only devices on your tailnet can reach the server, and WireGuard
  encrypts the traffic, so plain HTTP is fine here. To expose it more widely, put TLS in front: add a `tls` key
  with a PKCS#12 identity. Tailscale can issue a certificate with `tailscale cert <machine>.<tailnet>.ts.net`
  when HTTPS is enabled for the tailnet; convert it with `openssl pkcs12 -export`. That also turns on HTTP/2 and
  HTTP/3.
- **Firewall.** If the macOS application firewall is on, the first time the unsigned `SwiftWebServer` binary
  listens on a non-loopback address, macOS asks on gordon's screen whether to accept incoming connections.
  Allow it once there.
- **When gordon's Tailscale address changes.** Re-run `deploy.sh`, which rewrites the config.
- **Busy model.** If the model is busy or down, Parallax waits up to 15 s per decision and then plays Planner.
  The proxy's `response` timeout (20 s) is set above that, so Parallax gives up first.
