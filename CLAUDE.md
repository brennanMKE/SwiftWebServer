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
- **Never touch the user's keychain.** No `security` commands, no keychain add/delete/trust changes. Load TLS identities in memory only (`SecPKCS12Import` with `kSecImportToMemoryOnly: true`). Test certificates and keys live in a gitignored folder created by script.
- Tests use Swift Testing (`import Testing`). Protocol logic is tested over in-memory transports; socket tests bind port 0.

## Parallel work (worker protocol)

Work happens in git worktrees, one issue per worker. The orchestrator merges to `main`; workers never merge to or push `main`.

1. **Sync first:** worktrees can start behind local `main`. Run `git checkout -b mNN-<item> && git merge --ff-only main` (or `git rebase main`) before any edit. Re-run `git merge main` before finishing.
2. Read `docs/ROADMAP.md`, `issues/Issues.md`, and `issues/NNNN.md` (if the issue file is missing, the orchestrator's prompt is the spec).
3. Stay inside the targets your issue names (and their test targets). Do not edit `Package.swift` unless the issue requires it — all targets are pre-declared. If you must add a dependency edge, keep the diff to that one line.
4. Verify: `swift build` and `swift test` pass with your new tests visibly running. Add benchmarks to `sws-bench` when the issue touches the hot path.
5. Commit code as `#NNNN <Verb> <title>`. Then, if `issues/NNNN.md` exists, do the resolve workflow from `issues/Issues.md` (status `resolved`, Closed, Commit, Root cause / Fix / Verification / Files changed / Gotchas) as a second commit `#NNNN Resolve: <title>`. Never touch other issue files.
6. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
7. Report back in under 10 lines: branch, commits, test counts, benchmark numbers if any, and deviations or follow-ups. If you can't finish, follow "When the subagent can't finish" in `issues/Issues.md` and say why.
