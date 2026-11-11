# SwiftWebServer — guidance for Claude

The design and milestone plan is `docs/ROADMAP.md`. Read it before any implementation work. Issue workflow is `issues/Issues.md`.

## Build and verify

```bash
swift build
swift test            # must show tests executing and a passing summary
```

Every change merged to `main` must pass both. Milestone-end comprehensive runs also include the integration tests and `swift run -c release sws-bench` (results recorded in `docs/benchmarks/`).

## Code rules

- Swift 6 language mode, strict concurrency, macOS 15+, **zero package dependencies**.
- No Combine. No `DispatchQueue` except inside `NetworkTransport` (Network.framework requires a queue) and signal sources in the executable.
- No actors on the request path. Shared mutable connection state uses `Mutex` (Synchronization) with non-suspending critical sections.
- No unstructured `Task {}` for connection or stream work; lifetimes are task-group trees.
- Protocol state machines are value types: `mutating func handle(_ event:) -> Action`, no I/O, no `await`, return a single action (never `[Action]`).
- `AsyncStream` only for low-rate signals. Byte and frame flows use demand-driven `AsyncSequence`s or `BoundedAsyncQueue`. Never unbounded buffering.
- Hot path (per request/frame): no allocations in our code, no `String`/Foundation, no existentials except `.stream` bodies. Parse bytes directly.
- Every optional feature lives in its own target and registers through the extension points in ROADMAP §5.2. Do not add feature code to `HTTPCore`, `HTTP1`, or `HTTPServer`.
- Tests use Swift Testing (`import Testing`). Protocol logic is tested over in-memory transports; socket tests bind port 0.

## Parallel work

Work happens in git worktrees on branches named `mNN-<item>` (e.g. `m01-bytebuffer`). Keep changes scoped to the targets your issue names to avoid merge conflicts. Do not edit `Package.swift` unless the issue requires it; all targets are pre-declared in M0.
