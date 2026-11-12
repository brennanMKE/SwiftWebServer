# Network.framework TCP transport: notes and measurements (#0078)

`NetworkTransport` adapts `NWConnection`/`NWListener` to `ByteStreamTransport`
(`TCPTransport`, `TCPListener`, `TCPConfiguration`). This note records how the adapter is
built, what Network.framework does underneath it, and what one round trip costs (ROADMAP §7,
"known floor").

## Design summary

- **Demand-driven reads.** Each `receive(into:maxLength:)` issues exactly one
  `receive(minimumIncompleteLength: 1, maximumLength: maxLength)` and appends the delivered
  `Data` straight into the caller's `ByteBuffer` tail (one `memcpy`, no intermediate buffer).
  Nothing reads ahead, so a task that stops reading applies TCP backpressure.
- **Sends** copy the `ByteBuffer` into `Data` (the one copy on the write path), send with
  `isComplete: true`, and resume on `.contentProcessed`. `endOfStream` uses `.finalMessage`,
  which is a TCP half-close (FIN). Receiving keeps working afterwards.
- **Handlers before `start`.** State and viability handlers are installed in `init`. The
  connection is started separately (#0010). The listener's state and new-connection handlers
  are installed in `TCPListener.init`, and `start()` comes after.
- **One serial `DispatchQueue` per connection, and one per listener.** This is the only
  `DispatchQueue` use in the package's mainline code.
- **Continuations.** Each one is an `UnsafeContinuation`, so the hot path has no
  `CheckedContinuation` box allocation. Each lives in a `Mutex` and is taken out under the
  lock before it is resumed. The NW callback, a state change, `close`, and task cancellation
  all race to take it, so it is resumed exactly once. The callback object (`Core`) holds no
  reference to the `NWConnection`, so the handlers do not form a retain cycle.
- **Cancellation.** NW cannot cancel a single outstanding receive or send. Cancelling a
  waiting task throws `CancellationError` at once and cancels the connection. Later calls
  throw `TransportError.closed`.
- **Bounded accept.** `TCPListener` holds at most `pendingConnectionLimit` connections that NW
  has handed over but `connections` has not yet taken (still in the handshake, or ready and
  waiting). Any connection beyond that is cancelled at once and counted in
  `rejectedConnectionCount`. `connections` is an `AsyncSequence` whose `next()` pops one
  connection or suspends. It yields connections only after `.ready`, so `info` (both
  addresses) is set before anyone sees the transport.
- **Binding.** The listener binds with `requiredLocalEndpoint` (default `127.0.0.1`, port 0).
  `start()` returns the real port from `listener.port` once the listener is `.ready`.
- **Socket options** live in `TCPConfiguration`: `noDelay` (default on), keep-alive
  idle/interval/count (default off), connect timeout, and `allowLocalEndpointReuse`.
- **Error mapping.** `ECONNRESET`, `EPIPE`, `ECONNABORTED`, `ENOTCONN` and `ENETRESET` map to
  `.connectionReset`. `ETIMEDOUT` maps to `.timedOut` and `ECANCELED` to `.closed`. Anything
  else maps to `.failed(code:)`.

## Network.framework behaviour observed

1. **A refused connect does not fail; it waits.** Connecting to a closed loopback port moves
   the connection to `.waiting(POSIX ECONNREFUSED)`, and NW retries on path changes forever.
   `TCPTransport.connect` therefore treats `.waiting` as a failure and cancels. Accepted
   connections do not do this.
2. **`forceCancel()` sends a TCP RST.** The peer's pending or next receive fails with
   `ECONNRESET`, which maps to `.connectionReset`. Bytes accepted by an earlier `send` were not
   delivered to the peer's reader. `close(.abort)` relies on this.
3. **`cancel()` is graceful and keeps accepted bytes.** A client that sends 100 MiB and calls
   `close(.normal)` right after its last `send` returns has every byte delivered, then EOF
   (`largeTransferAppliesBackpressure`). So `.contentProcessed` plus `cancel()` is enough, and
   no explicit FIN-then-wait is needed.
4. **Loopback backpressure is tight.** When the server does not read, the client's sends stall
   after about 1.2–1.8 MiB has been accepted (socket buffers plus NW's own). That is much
   less than the several MiB per stream that the QUIC spike saw. The 100 MiB test asserts that
   the accepted count stays below 32 MiB and stops changing.
5. **A cancelled pending receive is reported as EOF or an error to the peer.** The test
   accepts either one.
6. **Cancelling an accepted connection that was never started** (the over-limit case) closes
   the socket. The client sees EOF or an error on its next receive. Starting the connection
   first is not needed.
7. **NWListener has `newConnectionLimit`.** It could give kernel-level backpressure, because NW
   stops handing over connections when the limit reaches 0. It was not used: what happens to
   connections that arrive while the limit is 0 is undocumented, and the explicit
   cancel-beyond-bound behaviour is what the issue asks for and is testable. Worth trying in
   #0079 if accept storms matter. (#0113: not tried. The profile puts the cost inside NW's own
   accept handling, `nw_listener_inbox_socket_handle_new_socket`, not in the hand-over to our
   handler, so limiting hand-overs is not expected to shorten it.)
8. **Accepting a connection is expensive, serialized, and gets slower with every new peer
   (#0113).** All Network.framework work for the process runs on one serial queue,
   `com.apple.network.connections`; our per-connection queues barely appear in a `sample`. In
   a new-connection-per-request load (16 clients, release build), 86% of samples were on that
   queue, mostly in `nw_listener_inbox_socket_handle_new_socket` →
   `nw_context_copy_registered_endpoint` → `nw_hash_table_get_node` → `nw_endpoint_is_equal`.
   NW creates an `nw_association` (with a path evaluator, parameters, and endpoints) for every
   distinct remote endpoint. It keeps the association for about 60 s after the connection
   closes (`heap` showed 10,586 of them after about 10,600 connections, and the count fell all
   at once roughly 60 s later), and the endpoint lookup slows down as that table grows. In
   back-to-back rounds of 4,000 connections, the rate fell from about 4,000/s to 800–1,400/s,
   then 300–1,400/s. Measured costs: about 665 µs of CPU and about 410 allocations per
   connection, a 2.5 ms p50 from `connect` returning to `newConnectionHandler`, and another
   2.4 ms to `.ready`. None of the public knobs changed this: a shared pool of 8 serial queues,
   a private `NWParameters.PrivacyContext` (with or without `disableLogging()`), and periodic
   `flushCache()` all stayed within noise. Cleartext TCP can therefore use
   `BSDSocketListener` (POSIX sockets + kqueue) instead; see `docs/benchmarks/M3-accept.md`.

## Measurements

`TransportBench.run(_:)` in `Sources/sws-bench/TransportBench.swift` is exposed only, not
wired into a command. It was run in-process over 127.0.0.1 from a temporary, uncommitted
`main.swift` case: a release build and one invocation of 3 rounds × {default, executor
preference}. Allocation counts are process-wide (client, server and NW threads) and come from
the `malloc_logger` hook (`AllocationCounter.countAsync`).

- Machine: Apple M4 Pro, 12 cores, 64 GB, macOS 27.0, Swift 6.4.2.
- **Load average 26.13 / 136.04 / 140.45 at the start (21.22 at the end).** Other agents were
  busy on the machine, so treat these as rough. The milestone-end idle run should replace them.

Median of 3 rounds:

| Case | Default | Executor preference |
|---|---|---|
| Echo 64 B round trip, p50 | 45.0 µs | 44.8 µs |
| Echo 64 B round trip, p99 | 67.1 µs | 67.2 µs |
| Echo round trip allocations (2 sends + 2 receives, both ends, NW) | 50.0 | 58.0 |
| Echo throughput, 64 KiB sends (each way) | 1342 MiB/s | 1442 MiB/s |
| `send` 64 B until `.contentProcessed` | 15.6 µs/call | 13.1 µs/call |
| `send` allocations (includes the server's reads) | 23.2/call | 26.8/call |
| `receive` 64 B with data already buffered | 6.60 µs/call | 5.89 µs/call |
| `receive` allocations | 12.0/call | 14.0/call |

Reading the numbers:

- **The per-read floor is about 6.5 µs and 12 allocations, nearly all of it inside NW.** Our
  code allocates one escaping completion closure per receive. The continuation is unsafe and
  does not allocate, and the copy goes into the reused buffer. The rest is NW's `Data`,
  dispatch blocks and internal bookkeeping. A `receive` therefore costs about 40 times the
  ROADMAP's 150 ns head-parse target. This confirms the ROADMAP's rule: read large
  (`maxLength` of 16–64 KiB) and parse all pipelined requests from one read. Never read small.
- **The per-write floor is about 11 allocations per send** (23.2 minus the server's
  receives). It includes the `ByteBuffer` to `Data` copy. A future experiment is
  `Data(bytesNoCopy:deallocator: .custom)` that retains the buffer's storage. That skips the
  copy, but the connection's reused output buffer would then hit copy-on-write on its next
  mutation if NW still holds the `Data`, so measure it before adopting.
- **Task-executor preference** (`TCPTransport.taskExecutor`, a `TaskExecutor` that runs jobs
  on the connection's queue, used with `withTaskExecutorPreference` and
  `group.addTask(executorPreference:)`): send and receive are about 10–15% faster and
  throughput about 7% higher. Echo latency does not change, and every call costs 2 more
  allocations (the `queue.async` block per enqueued job). On a loaded machine that is not a
  clear win, so it **stays opt-in and is off by default**. Re-measure on an idle machine when
  the HTTP/1.1 runner exists (M3), since that is where the per-request hop count is decided.
  An executor that runs jobs inline when it is already on the queue, instead of always calling
  `queue.async`, might remove the extra allocations.

## Tests

`Tests/NetworkTransportTests/TCPTransportTests.swift`: every test binds 127.0.0.1 port 0, has
`.timeLimit(.minutes(1))`, and runs under `scripts/guarded.sh`. The tests cover:

- Echo with a raw `NWConnection` client and with two `TCPTransport`s.
- Peer EOF returns 0 and stays 0, and half-close works.
- A 100 MiB transfer with a stalled reader (backpressure), then a full drain with a checksum.
- Abortive close resets the peer. A cancelled pending receive throws. A concurrent receive is
  rejected, and `close` fails a receive in progress.
- The bounded accept queue (limit 2, five clients, three rejected), two listeners in one
  process, a connect failure before `.ready`, listener close and accept cancellation, and a
  `/usr/bin/curl` exchange.

# TLS over TCP (#0087, #0088)

`TCPListener(configuration:tls:)` with a `TLSConfiguration` layers `NWProtocolTLS` over TCP.
TLS stays on Network.framework even though cleartext defaults to BSD sockets (ROADMAP §2).

- **Identity** is a `TLSIdentity` (PKCS#12, `kSecImportToMemoryOnly`), set with
  `sec_protocol_options_set_local_identity`. Minimum TLS 1.2; NW negotiates TLS 1.3 whenever
  the client offers it. ALPN tokens come from `TLSConfiguration.alpn`, which the caller builds
  from `ProtocolRegistry.alpnTokens`. Client authentication (a verify block plus
  `sec_protocol_options_set_peer_authentication_required`) is off unless configured.
- **Hand-over after the handshake.** An accepted connection reaches `.ready` only once the
  TLS handshake is done, so `connections` yields it with `ConnectionInfo.isSecure`,
  `negotiatedALPN` (`sec_protocol_metadata_get_negotiated_protocol`) and `tlsVersion` already
  set. The handshake happens while the connection holds a pending-queue slot.
- **Handshake timeout.** A client that connects and never finishes the handshake would hold
  that slot forever, so each TLS connection gets a timer on the listener queue
  (`TLSConfiguration.handshakeTimeout`, default 10 s) that `forceCancel`s it if it is still
  preparing.
- **Failures** are logged (`os.Logger`, subsystem `SwiftWebServer`, category `TLS`), counted
  in `failedHandshakeCount`, and dropped; nothing is handed over.
- **No identity reload.** NW copies the listener's parameters when the listener is created and
  has no public server-side hook to pick an identity per handshake, so a new identity needs a
  new listener. Not done here.

Observed:

1. A cleartext request on the TLS port fails the handshake at once (`.failed`, not
   `.waiting`); the client sees the connection end.
2. A client offering only an ALPN token the server does not list gets a
   `no_application_protocol` alert: NW fails the handshake rather than continuing without ALPN.
   A client offering no ALPN at all completes the handshake with `negotiatedALPN == nil`.
3. With client authentication required and a client without a certificate, a TLS 1.3 client
   reaches `.ready` before the server rejects it; the refusal shows up as the connection
   ending on the client's first receive.
4. curl and `URLSession` negotiate TLS 1.3 (`AEAD-CHACHA20-POLY1305-SHA256` for curl).
5. Keep-alive throughput is 36% below cleartext over NW (`docs/benchmarks/M5-tls.md`).

# Network.framework QUIC transport (#0098)

`QUICListener` (`NWListener` + `newConnectionGroupHandler`), `QUICConnection` (one
`NWConnectionGroup`, a `MultiplexedTransport`) and `QUICStreamTransport` (one stream
`NWConnection`, `ByteStreamTransport & StreamIdentified`) follow the spike's API shape
(`docs/spikes/quic-spike.md`). The decisions in `QUICConnectionState` / `QUICStreamState` are
pure value types; the classes hold continuations in a `Mutex`, as in the TCP adapter. One
serial queue per connection runs the group and all its streams.

- **Inbound streams** are started at once (the ID is only readable when ready) and handed over
  in ready order through a demand-driven sequence. At most `pendingStreamLimit` are held; the
  rest are reset with `rejectedStreamErrorCode`.
- **Stream credit.** NW never replenishes MAX_STREAMS. When a peer stream finishes (cancelled or
  failed after it was ready), the adapter sets the group's `localMaxStreamsBidirectional` /
  `Unidirectional` to initial + finished. Without this, the conformance test stalls until the
  idle timeout. `QUICConnection` is also `StreamCreditGranting` (#0102): HTTP/3 raises the limit
  to its own `maxConcurrentRequestStreams` (+ finished requests) through `raiseMaxStreams`,
  which only ever raises it and runs on the connection's queue.
- **Sends** are split into `sendChunkSize` chunks (64 KiB), each waiting for `.contentProcessed`.
  NW's own per-stream buffer cannot be bounded: with a stalled reader a client accepted about
  4.1 MiB (256 KiB stream window plus NW buffering) before sends stalled. In memory the same
  test stalls at 64 KiB.
- **Close** sets the group's `applicationError` (with a non-nil reason), `forceCancel`s every
  ready stream, `cancel`s never-ready ones, then cancels the group.
- **Names.** macOS 26's Network module declares `QUICStream`, so ours is `QUICStreamTransport`.

Behaviour observed while building it:

1. `NWProtocolQUIC.Metadata.applicationError = ApplicationError(code:)` with a nil `reason`
   crashes with SIGSEGV. Always pass a reason (`""` is fine).
2. A plain `cancel()` of a stream during connection close sometimes reaches the peer as FIN, so
   a truncated response would look complete. `forceCancel()` gives the peer `ECONNRESET`.
3. Setting `streamApplicationErrorCode` on each stream just before cancelling the streams and
   the group made a spurious server-initiated bidirectional stream (ID 1) show up at the NW
   client. `reset(applicationError:)` on a single stream does not do this.
4. A client whose verify block rejects the server's certificate gets no TLS error: its group
   stays `waiting(ENETDOWN)`, while the server group fails with `EINVAL`. `connect` therefore
   relies on `connectTimeout`.
5. After the peer closes the connection, an NW client's streams fail with `ENETDOWN` or
   `ECONNRESET`, and its group fails with `EINVAL`. All of these map to `.connectionReset`, and
   inbound iteration then ends with `nil`, which matches the in-memory transport.

Tests: `Tests/NetworkTransportTests/MultiplexedTransportConformanceTests.swift` runs 9 scenarios
against both implementations. `QUICTransportTests.swift` covers a raw `NWConnectionGroup`
client, stream bounds, credit, the identity loader, the state machines, and one
`curl --http3-only -k` request served with the spike's hand-encoded HTTP/3 response.

## Peer aborts and the connection close code (#0104)

### Peer aborts while nothing is pending

`QUICStreamTransport` is `PeerAbortObserving` (HTTPCore): `waitForPeerAbort()` returns when the
peer resets the stream or sends STOP_SENDING, even if no receive or send is in progress.
HTTP/3 uses it to cancel a handler that is still computing after the request ended.

6. **A peer abort fails the stream `NWConnection` on its own.** With the request already read
   to FIN and nothing pending, a peer `reset(applicationError:)`, `forceCancel()` or even a
   plain `cancel()` of its stream moved the server's stream to `.failed(ECONNRESET)` (then
   `.cancelled`) within a few milliseconds; the next send failed with `connectionReset`.
   `waitForPeerAbort()` resumes on that state change, on a receive or send failing with
   `connectionReset`, or on the stream ending. A raw NW receive issued after FIN completes at
   once with `ENOMSG`, so polling receives would not work.

### Spike open question 6: is our CONNECTION_CLOSE code on the wire? No.

`QUICConnection.close(applicationError:)` sets the group's
`NWProtocolQUIC.Metadata.applicationError` and cancels the group. To see what reaches the
peer, `Tests/NetworkTransportTests/QUICCloseCodeTests.swift` runs Homebrew curl (ngtcp2)
through a loopback UDP relay (`UDPRelay`) that keeps every datagram, with `SSLKEYLOGFILE` and
`QLOGDIR` set. It decrypts the server's 1-RTT packets after the close with curl's
`SERVER_TRAFFIC_SECRET_0` (`QUICShortHeaderDecryptor`; NW and curl negotiate
TLS_AES_256_GCM_SHA384 on loopback) and reads curl's qlog. No capture, root or new installs.

7. **Network.framework never sends an application CONNECTION_CLOSE (0x1d).** In 20+ runs with
   codes 0x100 and 0x107, both with the adapter's close (reset every stream, then cancel the
   group) and with only setting `applicationError` and cancelling the group:
   - after the cancel the server sends only STOP_SENDING / RESET_STREAM with code 0 for every
     stream, plus STOP_SENDING and a FIN on server-initiated stream 1, which it never opened
     (compare observation 3 above);
   - curl then closes the connection itself (transport NO_ERROR after a reset request stream,
     or transport INTERNAL_ERROR after the unexpected stream 1);
   - the only CONNECTION_CLOSE from the server, in some runs, is a transport one (0x1c) with
     NO_ERROR, mostly sent after curl's own close.

   So the code we pass to `close(applicationError:)` (`H3_NO_ERROR`, `H3_EXCESSIVE_LOAD`,
   `H3_CLOSED_CRITICAL_STREAM`, ...) does not reach the peer over Network.framework. This is a
   **known limitation**: a peer sees the connection end, but not why. Per-stream codes
   (RESET_STREAM, STOP_SENDING) do reach it. The in-memory transport still reports the code
   (`peerCloseApplicationError`), so HTTP/3 tests assert it there. The probe test records
   "our code arrived" as a known issue, so it reports when a macOS release starts sending it.

The abuse limits that end with `H3_EXCESSIVE_LOAD` (#0104) therefore look like a plain
connection teardown to an NW-hosted server's peer.

## Races seen under heavy load (#0115)

8. **The reset code must be read when the stream fails, not only on a failed receive.** A peer
   reset moves the stream to `.failed(ECONNRESET)` on its own (observation 6). Under load that
   state change can land between two receives; the next receive then fails from the stored
   failure and never read `streamApplicationErrorCode`, so `receivedResetCode` stayed `nil`.
   `QUICStreamTransport` now also reads the code in its `.failed(ECONNRESET)` handler (as the
   RESET_STREAM code while this end still receives, else as the STOP_SENDING code). Forcing
   that ordering (`waitForPeerAbort()` before the receive) failed every time before the fix.
9. **The phantom server stream 1 reaches an NW peer on every close.** A raw NW client's
   `newConnectionHandler` got a new stream after every `QUICConnection.close` (15 of 15),
   also with no `applicationError` set and without reading the group metadata at ready, so
   neither is the trigger. A `QUICConnection` client normally fails its group (`EINVAL`) before
   that stream becomes ready, and its pending inbound streams are dropped with the group. In
   about 1 of 150 closes under load it became ready first (ID 1, no data, then
   `.failed(ENOTCONN)` with no code) and was handed to `inboundStreams`. The transport cannot
   tell it from a real server-opened bidirectional stream 1 when it becomes ready (other QUIC
   stacks may legitimately open one), and it is only seen by clients, which
   HTTP/3 here never is, so it is surfaced; tests that drain a client's inbound streams after a
   peer close allow that one dead stream.
