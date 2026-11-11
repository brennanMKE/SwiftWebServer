# QUIC spike (#0071, Milestone 0.3)

Can Network.framework's `NWProtocolQUIC` serve as the substrate for HTTP/3 (ROADMAP §6, Option A)?
The spike package is in `Spikes/QUICSpike/`. It is standalone, with its own `Package.swift`, and does not touch the root package.

## Environment

| | |
|---|---|
| OS | macOS 27.0 (26A428), arm64 |
| Toolchain | Swift 6.4.2 (swiftlang-6.4.2.1.9), Command Line Tools SDK; package deployment target macOS 15 |
| API surface | `Network.swiftmodule/arm64e-apple-macos.swiftinterface` plus `Network.framework/Headers/quic_options.h` |
| Peers | the spike's own NW QUIC client; Homebrew curl 8.23.0 (ngtcp2 1.26.0, nghttp3 1.19.0, OpenSSL 4.1.0; `curl -V` lists `HTTP3`); `URLSession` |
| Wire evidence | curl `QLOGDIR=` qlog traces. No packet capture: `/dev/bpf*` is root-only, and installing aioquic was not permitted |

## How to run

```bash
cd Spikes/QUICSpike
./make-identity.sh                     # openssl: self-signed localhost cert + identity/identity.p12 (gitignored)
swift build && swift build -c release
./run-scenario.sh -- .build/debug/quic-client echo --port PORT        # echo|uni3|reset|peerreset|close <v>|stall|bulk|zerortt|urlsession
./run-scenario.sh -- /opt/homebrew/opt/curl/bin/curl -sv --http3-only -k https://127.0.0.1:PORT/
./run-scenario.sh --server-args "--h3-reset 10c" -- /opt/homebrew/opt/curl/bin/curl -sv --http3-only -k https://127.0.0.1:PORT/
BUMP_MAX_STREAMS=1 QUIC_SPIKE_QUIET=1 QUIC_SPIKE_ALLOCS=1 BIN=.build/release \
  ./run-scenario.sh -- .build/release/quic-client loop 5000 50 --port PORT
```

- `run-scenario.sh` starts `quic-server` on 127.0.0.1 with port 0 under `scripts/guarded.sh`. It substitutes the real port for `PORT`, runs the client under the guard, then stops the server.
- The server accepts two ALPNs on one listener:
  - `h3`: a minimal HTTP/3 server. It opens control, QPACK encoder and QPACK decoder uni streams. It answers every request with a hand-encoded HEADERS frame (QPACK prefix `00 00`, static indexed `:status 200` = `0xD9`, `content-type` = `0xF5`) followed by a DATA frame.
  - `sws-echo`: on each bidi stream, the first line is a command that selects a test behaviour.

## Results

| # | Question | Result | Evidence |
|---|---|---|---|
| 1 | QUIC `NWListener` with a local identity accepts `curl --http3-only -k` and an NW QUIC client | **Works** | curl: TLSv1.3 handshake, `using HTTP/3`, `< HTTP/3 200`, body `hello from NWProtocolQUIC h3`, exit 0. curl's qlog shows our transport parameters honoured (`initial_max_data=1048576`, `initial_max_stream_data_bidi_remote=131072`, `initial_max_streams_bidi=200`). NW client (`NWConnectionGroup` + `NWMultiplexGroup`, ALPN `sws-echo`): group `.ready`, `negotiatedALPN=sws-echo`, TLS 0x0304. Both use one listener with ALPN `["h3","sws-echo"]`. |
| 2 | Inbound stream direction and ID readable once ready | **Works** | `NWProtocolQUIC.Metadata.streamIdentifier` is valid in `.ready`. With curl the server saw ids 0 (bidi), 2, 6, 10 (client uni: control, QPACK enc, QPACK dec; first bytes 0x00/0x02/0x03). The Swift overlay has no direction property, but the RFC 9000 id bits give it (`id & 0x2` = uni, `id & 0x1` = server-initiated). The C call `nw_quic_get_stream_type` also returns it, but the Swift `NWProtocolMetadata` cannot be bridged to `nw_protocol_metadata_t`. |
| 3 | Server opens 3 unidirectional streams | **Works** | `NWConnection(from: group, using: NWProtocolQUIC.Options` with `direction = .unidirectional)` produced streams 3, 7 and 11. The NW client received all three through `group.newConnectionHandler`, each with its data and FIN. curl accepted our control, QPACK encoder and QPACK decoder streams. |
| 4 | FIN mapping both ways | **Works** | Sending `.finalMessage` with `isComplete: true` produces FIN: the peer's `receive` reports `isComplete=true`, either on the last data chunk or as a separate 0-byte completion. Sending `content: nil` with `.finalMessage` also works as a bare FIN. On receive, `isComplete` is true only at the peer's FIN; a `.defaultMessage` + `isComplete: true` send does not set it. `ContentContext.isFinal` reads true on every receive, so it carries no information. |
| 5 | RESET_STREAM / STOP_SENDING codes | **Works** | Setting `stream metadata.streamApplicationErrorCode = 0x10c` and then calling `cancel()` showed up in curl's qlog as `reset_stream stream_id=0 error_code=268`, and curl printed `HTTP/3 stream 0 reset by server (error 0x10c REQUEST_CANCELLED)`. An NW peer sees the reset as `receive` error `POSIX 54 ECONNRESET` with `isComplete=true`, and afterwards its own stream metadata `streamApplicationErrorCode` reads the peer's code (0x10c, 0x10b in the reverse direction). Before any reset it reads `0xffffffffffffffff`. `cancel()` on a receive-only peer uni stream sent `stop_sending` (code 0 when unset). The STOP_SENDING code with a non-zero value was not observed on the wire. |
| 6 | Close the connection with an application error code via group metadata | **Partial** | Setting `group metadata.applicationError = .init(code: 0x101, reason:)` reads back 0x101, but I could not confirm that code on the wire. On its own, `group.cancel()` sends nothing while any stream `NWConnection` is still alive: the NW client stayed `.ready` until the 30 s idle timeout. Cancelling every stream (including an un-started inbound stream; see gotchas) and then the group does close the connection. The NW client then sees the stream fail (`ENETDOWN`, or `ECONNRESET` with `forceCancel`) and the group fail (`EINVAL`), and its metadata never exposes the peer's code (`0xffff…` or nil). With curl, the group-first close produced a packet that curl's ngtcp2 rejected (`read_pkt -> ERR_CALLBACK_FAILURE`, "shutdown by server"). The qlog does not decode that packet, so the 0x101 CONNECTION_CLOSE is unproven. |
| 7 | Backpressure from not calling `receive`; send completion as signal | **Works** (coarse) | Client to server: the server stopped calling `receive` for 3 s. Client `.contentProcessed` completions fired immediately up to about 2.1 MiB, then one completion took 3113 ms and resumed as soon as the server read. The server then drained 8 MiB in 10.7 ms. Server to client: with the client not reading, server completions stalled after about 5.8 MiB (latency 3064 ms) and resumed once it read. So flow control does propagate, and completion means "accepted into NW's buffer". That buffer is several MiB per stream, well above the 128 KiB stream / 1 MiB connection windows we advertised, and is not configurable. We need our own bounded queues (as ROADMAP already requires). |
| 8 | 0-RTT | **Fails** (not available) | Server: `earlyDataAccepted=false` on every connection. curl with `--tls-earlydata`, forced onto fresh connections: no `0RTT` packets in its qlog, and no NewSessionTicket (no CRYPTO frames in 1-RTT packets) from the server. The NW listener therefore issues no tickets, so neither resumption nor 0-RTT is possible. NW client with `allowFastOpen` + `sec_protocol_options_set_tls_resumption_enabled/tickets_enabled`: `NWConnection(from: group)` returns nil before the group is ready, so early data cannot be queued; `earlyDataAccepted=false`. No server-side switch exists in the public API (`sec_protocol_options_*` has no server early-data option). Practical consequence: there is no replay risk, and the `Early-Data`/425 handling can be deferred. |
| 9 | Per-stream cost | **Works** (measured) | Release build, loopback, one connection, `ping\n`+FIN then `pong`+FIN, process-wide `malloc_logger` counter. Sequential (1 in flight), 2000 streams: 0.77–0.82 ms per stream round trip (about 1,250–1,300/s). Concurrency 50, 5000 streams: 0.39–0.44 ms per stream (about 2,300–2,600/s). Allocations: about 587–591 per stream on the server and about 288–293 on the client. Both figures include Network.framework internals and the spike's own Task, continuation and `Data` overhead, so treat them as an upper bound for NW plus a naive adapter. |
| 10 | TCP and UDP listeners on the same port number | **Works** | With the QUIC listener on an ephemeral port P (127.0.0.1), a TCP `NWListener` with `requiredLocalEndpoint` 127.0.0.1:P reached `.ready`. In one run, `curl http://127.0.0.1:P/` returned `tcp` and `curl --http3-only https://127.0.0.1:P/` returned the h3 body. |
| 11 | Client tooling | **Works** | Homebrew curl 8.23.0 has HTTP3 (ngtcp2) and works with `-k`; `QLOGDIR` gives wire-level evidence. `URLSession` with `URLRequest.assumesHTTP3Capable = true` and a delegate that answers `NSURLAuthenticationMethodServerTrust` with `URLCredential(trust:)`: `networkProtocolName=h3`, status 200, `Content-Type: text/plain`, correct body. A minimal hand-encoded HTTP/3 response (QPACK static-indexed fields, no dynamic table, SETTINGS `QPACK_MAX_TABLE_CAPACITY=0`, `QPACK_BLOCKED_STREAMS=0`) is accepted by both curl and URLSession. |

## Gate verdict

**NO-GO as the gate is written, because Q6 is Partial. Everything else in 1–7 works.** My recommendation is to treat this as a narrow, conditional NO-GO, not a reason to promote Option B:

- Q1–Q5 and Q7 work, and curl and URLSession interoperate with a hand-rolled HTTP/3 layer on top.
- Q6's mechanism works: cancelling all streams and then the group ends the connection promptly. What is missing is proof that the application error code (for example `H3_NO_ERROR` 0x100 or `H3_FRAME_ERROR`) is actually carried in CONNECTION_CLOSE. No peer available here exposes it: the NW client hides it, curl's qlog did not decode the closing packet, and packet capture needs root.
- Proposed follow-up (about 2 hours) before Track A proceeds: put a loopback UDP relay in the spike and decrypt with curl's `SSLKEYLOGFILE`, or use an aioquic peer if the owner allows installing it, to confirm the CONNECTION_CLOSE code. If the code is not sent, HTTP/3 connection errors degrade to "close without a code". That is non-conformant for error signalling but harmless for clients in practice, and the owner should decide whether it is acceptable.

## Gotchas (exact API usage that worked)

1. **Identity must be imported in memory.** Use `SecPKCS12Import(data, [kSecImportExportPassphrase: pw, kSecImportToMemoryOnly: true], &items)` (macOS 15+). Without `kSecImportToMemoryOnly`, macOS adds the key to the login keychain. The first TLS signature then blocks on a SecurityAgent prompt, and the handshake silently hangs. This happened once during the spike: the identity was added to the login keychain, I removed it with `security delete-identity`, and I reported it to the coordinator. Then `sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(identity)!)`. The PKCS#12 is written with `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` for compatibility with SecPKCS12Import.
2. **Bind to loopback.** Set `params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 0)` and call `NWListener(using: params)` (no `on:`); read the port from `listener.port` once `.ready`. Binding to all interfaces with an unsigned binary can trigger the firewall prompt.
3. **Client groups need a `newConnectionHandler` set before `start`.** Without one, `NWConnectionGroup(with: NWMultiplexGroup(to:), using:)` never leaves setup: no state callbacks and no packets. `NWConnection(from: group)` returns nil until the group is `.ready`.
4. **Every send must use `isComplete: true`.** `.defaultMessage` with `isComplete: false` leaves a message open, and a later send with another context (`.finalMessage`) queues behind it forever: no bytes, no FIN, no completion. Use `.defaultMessage, isComplete: true` for data and `.finalMessage, isComplete: true` (content may be nil) for FIN.
5. **MAX_STREAMS is not replenished automatically.** After `initialMaxStreamsBidirectional` streams (200 here), new client streams stall even when earlier ones have closed. Raising `groupMetadata.localMaxStreamsBidirectional` from `newConnectionHandler` fixes it (`BUMP_MAX_STREAMS=1`; 5000 streams OK). An HTTP/3 server must manage stream credit itself, presumably `localMaxStreamsUnidirectional` too.
6. **`group.cancel()` alone does not close the QUIC connection while any stream `NWConnection` is alive**, including inbound streams you never started. Track every stream per group and cancel them all, then the group.
7. **Group state is not a reliable gate for streams.** Every group reports `waiting(ENETDOWN)` first. With URLSession, inbound streams were `.ready` while the group was still `waiting`, and group `negotiatedALPN` was nil. Route by stream metadata (`streamMeta.negotiatedALPN`) and don't wait for group `.ready` before serving. Opening our control stream should be triggered by the first inbound stream or by group ready, whichever comes first.
8. **The NW client consumes client bidi stream 0 implicitly.** The first app stream is id 4, and the server sees an extra inbound stream that never leaves `preparing`. This only matters with NW clients, but it must be cancelled at shutdown (gotcha 6).
9. **Reset**: set `streamMeta.streamApplicationErrorCode = code`, then `stream.cancel()`. That sends RESET_STREAM(code). Plain `cancel()` without a code on a bidi stream behaved like FIN in one test. `forceCancel()` sends RESET_STREAM(0). The peer reads the code from its own stream metadata after `receive` fails with `ECONNRESET`.
10. Errors on a peer connection close: streams fail with `ECONNREFUSED`/`ENOTCONN`/`ENETDOWN`, and the group fails with `EINVAL`. None of these carries the application code.
11. A lazily-initialised global (`let spikeStart = DispatchTime.now()` in another module) initialises on first read, so `now() - spikeStart` overflowed and trapped. Read the global first. This affects spike tooling only, but the same lazy-init timing can matter elsewhere.
