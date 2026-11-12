# M15: WebSocket extensions (#0110)

What permessage-deflate (RFC 7692) costs and saves on a typical WebSocket stream: compression
ratio and CPU per message for the compressor (server to client) and the decompressor (client to
server), at the default settings and the alternatives a deployment might pick.

- Date: 2026-11-11, 18:31 PST
- Branch: `m15-ws` (on `main` `d8bf2a8`)
- Load average (1, 5, 15 min): 4.01 3.65 7.69, 3.78 3.61 7.63, 3.72 3.60 7.60 for the three runs.
  Not a gating record (the orchestrator runs those at milestone end).

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Command | `sws-bench micro --filter WebSocket` (200 samples, three runs, median run shown) |

## The stream

`WebSocketFixture.messages` in `Sources/sws-bench/WebSocketBench.swift`: 1,000 JSON messages
from a fixed pseudo-random sequence, 123,698 bytes in all (124 bytes on average): half
market quotes, 30% trades, 20% chat lines. Keys repeat in every message; prices, sizes,
timestamps and sequence numbers drift. This is the shape of most WebSocket APIs (market
data, chat, presence, game state): many small messages that share structure with the ones
before them.

One op compresses (or inflates) one message, cycling through the stream, so the compressor's
window holds the preceding messages as it would on a live connection. Sizes are frame payload
bytes (deflate output without its `00 00 ff ff` tail), the 2-byte frame header aside.

## Results

| Configuration | Stream bytes | Ratio | Deflate ns/message (median) | p99 | allocs |
|---|---|---|---|---|---|
| none | 123,698 | 1.000 | – | – | – |
| level 1, context takeover | 31,747 | 0.257 | 1,683 | 3,090 | 0 |
| **level 6, context takeover (default)** | **23,374** | **0.189** | **2,463** | 4,496 | 0 |
| level 9, context takeover | 22,375 | 0.181 | 5,901 | 8,839 | 0 |
| level 6, window 2^10, context takeover | 35,769 | 0.289 | 3,726 | 7,327 | 0 |
| level 6, `server_no_context_takeover` | 106,517 | 0.861 | 4,984 | 5,511 | 0 |

| Decompression | Inflate ns/message (median) | p99 | allocs |
|---|---|---|---|
| context takeover (default) | 208 | 1,492 | 0.03 |
| `client_no_context_takeover` | 664 | 3,287 | 0 |

Throughput at the default: about 50 MB/s of JSON per core compressed (2.5 µs for 124 bytes),
about 600 MB/s inflated.

## Findings

- **Context takeover is what makes permessage-deflate pay off for small messages.** With it,
  the default compresses the stream to 19% of its size; without it, each 124-byte message is
  compressed alone and the stream only shrinks to 86% (most messages are sent uncompressed,
  because the compressor's output is not smaller). The default keeps context takeover on
  both sides.
- **No context takeover is also slower**, 5.0 µs against 2.5 µs per message: `deflateReset`
  clears zlib's hash tables (tens of KiB at memory level 8) after every message. Its only gain
  is not holding history between messages, and the state stays allocated either way.
- **Level 6 is the default.** Level 1 is 1.5× faster for a 36% bigger stream; level 9 is
  2.4× slower for 4% smaller. Unlike the 50 KiB HTML page of #0091 (where level 6 was 4.5×
  level 4), small JSON messages give zlib short hash chains, so level 6's lazy matching costs
  little.
- **A smaller window costs ratio and CPU** here: a 2^10 window cannot reach back far enough to
  find the previous message of the same type, so most of context takeover's gain is lost.
  Keep 2^15 unless memory per connection matters more (about 256 KiB of zlib state for the
  compressor and 44 KiB for the decompressor per connection at the defaults, held for the
  connection's life).
- **Decompression is cheap**: 0.2 µs per message, an order of magnitude below compression, so
  accepting compressed messages from clients costs little; the inflated-size limit
  (`maxMessageSize`, 1009 beyond) is what bounds its memory.
- Neither direction allocates per message: the session reuses its output buffer and the zlib
  state lives for the connection.

## Not measured here

- End-to-end throughput over a socket: on loopback the bytes saved are free, so it would show
  only the CPU above. On a real network, 81% fewer bytes per message is the point.
- WebSockets over HTTP/3 (#0111) adds DATA framing (2–3 bytes per write) on the QUIC stream; it
  has no benchmark of its own.
