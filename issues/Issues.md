# SwiftWebServer

SwiftWebServer is a dependency-free, modular HTTP/1.1 + HTTP/2 + HTTP/3 server for macOS 15+ written in Swift 6 with Swift Concurrency and Network.framework. It serves static files from `Root/Public`. The design and milestone plan is `docs/ROADMAP.md`; code rules are in `CLAUDE.md`. Bugs, conformance gaps, security problems, performance work, and feature work for every protocol track all belong here.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The `# SwiftWebServer` heading above should match the `name` field in `issues/project.json`. `project.json` is the canonical source for the project's identity (name + repo URL); this guide is the workflow companion.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
├── 0001.md            # one file per issue
├── 0001/              # optional sibling folder for screenshots, crash logs, etc.
│   └── screenshot.png
├── 0002.md
└── …
```

## Project config (`project.json`)

A small JSON file naming the project and its repo. Two required fields:

```json
{
  "name": "SwiftWebServer",
  "url": "https://github.com/user/repo"
}
```

- `name` — the project's human-readable name. Match the heading at the top of this file.
- `url` — the project's canonical web URL (HTTPS form, not SSH). Typically a GitHub URL; GitLab, Bitbucket, etc. work too.

When the repo moves or renames, edit `project.json` directly. Don't infer the project's name from the parent folder path — `project.json` is authoritative.

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table. The Mac app converts to the display name when rendering.

## Critical rule: never close without explicit confirmation

The most important rule of this workflow: an issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language. Specifically, do not infer resolution from:

- a code change you (or a subagent) just made
- a commit message
- the filing of a related issue
- the user saying "thanks, that looks better"

Leave status at `open` (or `in-progress` if work has started) until the user confirms in words like "close this", "this is fixed", "mark resolved", or "won't fix". When in doubt, ask.

The deliberate exception: a subagent that finishes a fix may set `resolved` (work-is-done-but-not-confirmed). It must not set `closed` — that's the user's call. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

This project's choice on whether `issues/` is in git determines whether lifecycle events produce commits. Check on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

- **Not a git repo, or `issues/` is ignored**: edit files only; never commit. The Mac app still tracks changes from the working copy.
- **`issues/` is tracked**: each lifecycle event below produces its own commit.

When tracked:

| Event | What's committed | Commit message |
|---|---|---|
| Initial setup | `project.json` + `Issues.md` together | `Add issue tracker setup` (or bundle with the first `#NNNN` commit) |
| File a new issue | the new `NNNN.md` (and `project.json` / `Issues.md` if newly created) | `#NNNN <issue title>` |
| Edit project config | `project.json` only | `Update project config` (or e.g. `Update project URL`) |
| Resolve — code commit | code changes only | `#NNNN <verb> <title>` |
| Resolve — resolution commit | markdown update (status + Closed + Commit + summary) | `#NNNN Resolve: <title>` |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

**Working-copy-only changes (no commit):**

- Setting status to `in-progress` at the start of work — transient; the resolve commits supersede it. Committing every status flip would create noise.

**Why two commits to resolve, not one:** the **Commit** metadata row records the hash of the code-fix commit, and that hash isn't known until *after* the code commit lands. Splitting resolution into a code commit and a resolution commit keeps each commit single-purpose ("fix the code", "document the fix") and lets the resolution commit reference the hash cleanly.

## Issue file format

Each issue is `NNNN.md` (4-digit zero-padded) with this structure:

```markdown
# NNNN — Title

| | |
|---|---|
| **Status** | open |
| **Module** | <module name(s)> |
| **Platform** | iOS · macOS · iPadOS · All |
| **First seen** | YYYY-MM-DD |

## Description

What is wrong. Lead with the punchline — the first paragraph shows in the Mac app summary.

## Steps to reproduce

1. …
2. …

## Expected behavior

What should happen.

## Actual behavior

What actually happens.

## Attachments

![caption](NNNN/screenshot.png)

## Notes

Any additional context, guesses at root cause, related code locations.
```

### Format details that matter

- **Title separator** is an em-dash (U+2014, `—`), not a hyphen.
- **Metadata field rows** must keep the field name in `**bold**` exactly.
- **Dates** are `YYYY-MM-DD`.
- **Module** can list multiple modules separated by ` / ` (e.g. `BlueskyFeed / BlueskyDataStore`).
- **Platform** is `iOS`, `macOS`, `iPadOS`, `All`, or any other string. `All` is treated as matching every platform filter.
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` is the result of a fix commit, also add a `**Commit**` row with the short hash (`git rev-parse --short HEAD`).
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

1. Confirm `issues/project.json` exists. If missing, create it (see schema above) before filing the first issue — `name` should match this guide's heading; `url` is the project's canonical web URL (HTTPS, not SSH).
2. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
3. Create `issues/NNNN.md` from the template.
4. Set status to `open`.
5. Use today's date for First seen.
6. Phrase the title as a single declarative sentence describing the bug, not a question or a fix description.
7. **If `issues/` is tracked by git**, commit the new file with message `#NNNN <issue title>` so the issue enters git history with its `open` status. If ignored, skip.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a fix commit, also add a `**Commit**` row with the short hash. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

## Resolving an issue (the standard workflow)

Each open issue is handled by a fresh subagent. The orchestrator picks the issue; the subagent does the work in isolation and returns when done.

### Orchestrator: pick and dispatch

1. **Get the queue from the script, not by reading issue files.** Reading every `NNNN.md` to find the next one is the most expensive mistake the orchestrator can make — it burns context on files the subagent will read again anyway.

   ```bash
   ~/.claude/skills/issues/scripts/list-issues.py                       # open, in-progress, recently resolved
   ~/.claude/skills/issues/scripts/list-issues.py full -n 0 --no-color \
     | awk '$2=="open" || $2=="in-progress"'                            # every candidate, by number
   ```

   Filter on the status *column* with `awk` — `grep 'open'` also matches titles containing the word.

   Pick **`in-progress` strays first**: one with nobody working it is abandoned work, closer to done than anything `open`, and invisible until someone resumes it. Otherwise take the lowest-numbered `open` issue, unless this file defines a dependency or phase order — then that order wins, since the issue number is only a filing order.
2. Spawn a fresh subagent with the issue id and instructions to follow the resolve workflow below.
3. When the subagent returns, move on to the next open issue (or stop if only one was requested).

If the user names a specific issue ("fix 0046"), dispatch to that id directly.

### Subagent: claim → fix → build → commit → resolve

A subagent starts with fresh context, so its first job is loading the project's conventions before touching anything.

1. **Orient in the project.** Read these in order, every time:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project-specific rules. **Authoritative for issue-tracking workflow.**
   - **`CLAUDE.md`** at the repo root, if it exists — project-wide guidance, code conventions, restricted areas, build/test commands. **Treat its instructions as binding.**
   - **`issues/NNNN.md`** — the issue you're working on, in full, including attachments in `issues/NNNN/`.

   If the two project guides disagree, prefer `CLAUDE.md` for code/repo conventions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown — working copy only, no commit. The Mac app picks it up immediately.
3. **Make the code changes** required to fix the bug.
4. **Build *and* run the project's verification command, and confirm tests actually executed and passed.** This step is mandatory and cannot be shortcutted.

   - **Compilation is not verification.** "It builds" / "it compiles" / "no type errors" does not count. Tests must actually run — unit tests execute, UI tests run on a simulator, the app launches, whatever the project defines as proof. A green build with zero tests run is a failure of this step.
   - **If you wrote or modified tests as part of the fix, you MUST execute those specific tests and observe them pass.** Confirm the test names you added appear in the run output, the counts increased, and the result was success. A test that compiles but never ran proves nothing.
   - **Read the output, don't just check the exit code.** "0 tests run", "skipped", "no tests found", or a "build succeeded" line with no test summary are red flags even when the exit code is 0. iOS in particular will report `xcodebuild` success when no tests actually executed.
   - **If verification cannot be run in your environment** (no simulator, missing credentials, hardware required, sandbox), you have not verified the fix. Do not mark the issue `resolved` — bail per "When the subagent can't finish" below, naming the verification step you couldn't run.
   - **If the build was already failing before you started**, note it on the issue and bail — don't fix unrelated breakage.

5. **Make the code commit.** Stage *only the code changes* (not the issue markdown yet). The message starts with `#NNNN` and a short, declarative title — pick the verb that actually fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, etc.); not every issue is a bug fix. Leave a blank line after the title, then add a paragraph of details. Example:

   ```
   #0046 Add navigation from avatar tap to profile

   The avatar tap on PostCardView was not wired to any NavigationLink.
   Threaded the author DID through the cell and connected onTapGesture
   to push ProfileView.
   ```

6. **Capture the commit hash** with `git rev-parse --short HEAD`.

7. **Update the issue markdown** to mark it resolved. **Precondition:** step 4 actually executed and passed. If it didn't, bail — don't resolve.

   - Change Status to `resolved`.
   - Add a `**Closed**` row with today's date.
   - Add a `**Commit**` row with the short hash from step 6.

   Then add a structured summary in this order so the issue becomes a primary-source record:

   - **`## Root cause`** — what was actually wrong (often different from the original report).
   - **`## Fix`** — the approach taken.
   - **`## Verification`** — the exact command(s) run and what was observed (e.g. "`xcodebuild test -scheme MyAppUITests` — 14 tests passed including the 3 new tests in `ReplyButtonUITests`"). If new tests were added, name them and confirm they ran. Mandatory — this is the audit trail that distinguishes "verified" from "compiled and hoped".
   - **`## Files changed`** — bulleted list, one bullet per file, with a short note describing what changed in each.
   - **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior, or anything a future engineer working on similar code should know. Skip if nothing is notable. Be specific — these notes accumulate across issues and feed future "common pitfalls" docs.

8. **If `issues/` is tracked by git, make the resolution commit.** Stage `issues/NNNN.md` and commit with message `#NNNN Resolve: <title>`. Body briefly notes which code commit it pairs with (the hash from step 6). If `issues/` is ignored or there's no repo, skip — the markdown change from step 7 is the entire record.

Status flow: `open` → `in-progress` → `resolved`. **Never set `closed`** — the user does that after verifying the fix.

### Build / verify command for this project

Every change merged to `main` must pass:

```bash
swift build && swift test
```

`swift test` must show test names executing and a passing summary.

**Milestone-end comprehensive runs.** The last issue of a milestone also runs the integration tests, `swift run -c release sws-bench` (results recorded in `docs/benchmarks/`; a regression over 10% blocks the milestone, see #0063), and the external checks that milestone's exit criteria name, for example:

- Run locally: `ROOT_PATH=$PWD/Root swift run SwiftWebServer` (until #0079 lands, stop the legacy server with `pkill -9 -f SwiftWebServer`).
- HTTP/1.1 load: `oha` (M3, M4).
- TLS: `curl -k https://localhost:8443/` and a `URLSession` test (M5).
- HTTP/3: `/opt/homebrew/opt/curl/bin/curl --http3-only -k https://localhost:8443/` (M9, M10); the system `/usr/bin/curl` has no HTTP/3.
- HTTP/2: `curl -v --http2-prior-knowledge http://localhost:8080/`, `curl -v --http2 -k https://localhost:8443/`, `h2spec`, `h2load` (M12, M13).
- WebSockets: `URLSessionWebSocketTask` echo tests (M14).

Tool prerequisites and the test identity come from #0072 (`scripts/check-tools.sh`, `scripts/make-test-identity.sh`).

### When the subagent can't finish

If the bug is unreproducible, out of scope, or the build won't pass after reasonable effort:

1. **Discard or stash any partial code changes** so the bail doesn't accidentally include half-done work.
2. **Revert status to `open`** in the issue markdown so the issue goes back into the queue.
3. **Add a `## Notes` section** describing what was tried, why work stopped, and what you'd try next. Be specific.
4. **If `issues/` is tracked by git**, commit the markdown change with message `#NNNN Notes: <one-line bail summary>`. If ignored, skip.
5. Return with a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

## Attachments

Screenshots, crash logs, console output, sample data, etc. live in a sibling folder `issues/NNNN/`. Reference them with paths *relative to the issue's `.md` file* — that means the folder prefix `NNNN/` is part of the link target. The bytes that ship are `1335/screenshot.png`, not `screenshot.png` and not `issues/1335/screenshot.png`.

```
issues/1335.md           ← the markdown that contains the link
issues/1335/screenshot.png   ← the file being linked

# inside 1335.md the link reads:
![caption](1335/screenshot.png)
```

Concrete example with both image and video attachments:

```markdown
## Attachments

![Reply button does nothing when tapped](1335/screenshot.png)
![Crash log](1335/crash.log)
[![Sidebar resize jitter](1335/sidebar-resize-jitter.poster.png)](1335/sidebar-resize-jitter.mov)
```

### Videos (`.mov`, `.mp4`, etc.)

Videos can't be embedded as `![…](…)` — markdown renderers treat that as an `<img>` and a `.mov` won't load. Instead, generate a poster frame with `qlmanage` and emit an image-inside-a-link (shown in the example above). Quick recipe — copy the video into `issues/NNNN/` first, then:

```bash
qlmanage -t -s 1280 -o issues/NNNN issues/NNNN/<basename>.<ext>
mv issues/NNNN/<basename>.<ext>.png issues/NNNN/<basename>.poster.png
```

`qlmanage` ships with macOS — no install. It reliably produces posters for AVFoundation-supported formats: `.mov`, `.mp4`, `.m4v`, `.qt`. For `.avi` it usually works; for `.mkv` and `.webm` it generally fails on stock macOS unless a third-party Quick Look generator is installed. If the rename step doesn't produce the `.poster.png`, fall back to the plain `![alt](NNNN/file.mov)` form with a `<!-- poster generation failed -->` HTML comment in the Attachments section. Don't apply the link wrapper to plain images, and don't generate posters for animated GIFs.

### macOS screenshot / screen recording filename gotcha

macOS Screenshot and Screen Recording filenames both use a **narrow no-break space** (U+202F) before AM/PM, visually identical to a regular space. A literal `cp` of the quoted filename will fail with "No such file or directory". Use a glob to skip past it:

```bash
mkdir -p issues/NNNN
cp ~/Desktop/Screenshot\ YYYY-MM-DD\ at\ H.MM.SS*PM.png issues/NNNN/screenshot.png
cp ~/Desktop/Screen\ Recording\ YYYY-MM-DD\ at\ H.MM.SS*PM.mov issues/NNNN/recording.mov
```

The `*` matches the U+202F. Substitute the actual timestamp; if you don't know which file the user means, list `~/Desktop/Screenshot*` or `~/Desktop/Screen\ Recording*` by mtime and pick the most recent.

## Module conventions for this project

Use these names in the **Module** row. Separate multiple modules with ` / `. They match the targets in `docs/ROADMAP.md` §5.1.

- `HTTPCore`: `ByteBuffer`, `HTTPFields`, request/response types, extension-point protocols, limits, `BoundedAsyncQueue`, date cache, shared pseudo-header validation
- `HTTP1`: HTTP/1.1 parser, serializer, chunked codec, connection state machine and runner
- `HTTPServer`: `Server`, `ServerConfiguration`, lifecycle state machine, protocol registry, listeners
- `NetworkTransport`: `NWListener`/`NWConnection` adapters for TCP, TLS (+ALPN) and QUIC
- `HeaderCompression`: prefix integers, string literals, Huffman (shared by HPACK and QPACK)
- `HPACK`: HTTP/2 header compression tables, decoder, encoder
- `HTTP2`: HTTP/2 frames, connection and stream state machines, flow control, limits
- `QPACK`: HTTP/3 header compression
- `HTTP3`: HTTP/3 frames, control and request streams, GOAWAY, Alt-Svc
- `WebSockets`: RFC 6455 and its HTTP/2 and HTTP/3 bootstraps
- `StaticFiles`: file mapping, containment, MIME, validators, conditional requests, Range
- `Compression`: content-coding component
- `VirtualHosts`: host-based routing component
- `Auth`: authentication component
- `AccessLog`: access logging and metrics component
- `Router`: method and path routing component
- `ConfigFile`: JSON config decoding into components (CLI only)
- `Bench`: `sws-bench` harness and benchmark results
- `Tests`: test infrastructure, `HTTPTestSupport`, integration tests, external tooling
- `Docs`: markdown docs and scripts
- `Legacy`: the pre-roadmap server, kept buildable until the M4 cut-over (#0086)

Older issues may still carry pre-roadmap module names (`Lifecycle`, `Connection`, `Transport`, `Semantics`, `Security`, `Config`, `HTTP2Frames`, `HTTP2Connection`, `FlowControl`, `TLS`, `Conformance`, `Performance`, `Optional`); leave them as filed.

## Milestones

Work proceeds in milestone order from `docs/ROADMAP.md` §8. **Milestone order wins over issue number order**: the issue number is only a filing order. Within a milestone, pick the lowest-numbered `open` issue whose **Blocked by** issues (in its `## Relation` section) are all resolved.

Tracks A (HTTP/3), B (HTTP/2) and C (WebSockets) are independent of each other and can run in parallel once their dependencies are met: Tracks A and B after M5 (Track A also needs a GO from the QUIC spike, #0071), Track C after M3. M6 components can be picked up any time after M4. Parallel work happens in git worktrees per `CLAUDE.md`.

Legacy issues 0001–0068 that ROADMAP §9 merges into newer issues stay `open` with a **Superseded by** line in their Relation block. Don't work them directly; work the superseding issue, whose acceptance tests include the legacy repro steps. The owner closes the legacy issue.

| Milestone | Name | Issues | Depends on | Exit criteria (summary) |
|---|---|---|---|---|
| M0 | Ground | #0069–#0072 | — | `swift test` runs real tests; legacy baseline recorded; QUIC spike go/no-go |
| M1 | Bytes and HTTP/1.1 codec | #0073–#0076 | M0 | Parses identically split at every byte offset; oversized head → 431; zero allocations; ns/request recorded |
| M2 | Transport and lifecycle | #0077–#0079 | M1 | Two servers on port 0 in one process; exit 0 on SIGTERM, 1 on bad config; per-read overhead measured |
| M3 | HTTP/1.1 connections | #0080–#0082 | M2 | In-memory + curl tests; slow-header client closed; keep-alive throughput vs baseline |
| M4 | Components, StaticFiles, cut-over | #0083–#0086 | M3 | Repro steps of 0003–0025 pass as tests; throughput beats baseline; flat memory on large file; `Legacy` deleted |
| M5 | TLS and protocol registry | #0087–#0089 | M4, #0072 | `curl -k https://localhost:8443/` and a `URLSession` test |
| M6 | Small components | #0090–#0094 | M4 | Each: unit tests, and no benchmark change when unregistered |
| M7 | Pure codecs (Track A; 7.1 shared with B) | #0095–#0097 | M5; spike GO for #0096 | RFC 7541 App. C Huffman vectors and RFC 9204 examples |
| M8 | QUIC transport (Track A) | #0098–#0099 | M5, spike GO | Echo test vs NW QUIC client incl. FIN and reset |
| M9 | HTTP/3 MVP (Track A) | #0100–#0103 | M7, M8 | `curl --http3-only -k` fetches static files, concurrent and large; in-memory malformed-frame suite |
| M10 | HTTP/3 hardening (Track A) | #0104–#0107, #0062 (h3 part via #0105), #0065 (h3 part via #0107) | M9 | Abuse limits tested; browser interop; load numbers; optional QPACK dynamic table and priorities |
| M11 | HTTP/2 codecs (Track B) | #0034–#0036, #0039–#0041 | M5, #0095 | RFC 7541 App. C vectors |
| M12 | HTTP/2 connections and streams (Track B) | #0042–#0052, #0058 (h2 routing) | M11 | `curl --http2-prior-knowledge` and `curl --http2 -k`, concurrent streams |
| M13 | HTTP/2 flow control and limits (Track B) | #0053–#0056, #0061, #0062 (h2), #0065 (optional) | M12 | `h2spec` passes; `h2load` numbers |
| M14 | WebSockets (Track C) | #0108–#0109 | M3 (and #0083) | `URLSessionWebSocketTask` echo tests; Autobahn when Docker is available |
| M15 | WebSocket extensions (Track C) | #0110 (optional), #0067 (RFC 8441 over h2), #0111 (RFC 9220 over h3) | M14; M12 for #0067; M9 for #0111 | Extended CONNECT echo on each |
| M17 | Reverse proxy | #0120–#0124 | M3, M4, #0113 (and M14 for #0123) | Static site at `/` plus `/cgi-bin` proxied to a localhost app over h1/h2/h3; WebSocket passthrough; benchmark vs Apache mod_proxy and nginx |
| — | Per-milestone benchmarks | #0063 | #0070 | Each milestone records a `sws-bench` run; a regression over 10% blocks it |
| — | Won't fix | #0066 (server push), #0068 (h2c Upgrade) | — | Status `wontfix` by owner decision (ROADMAP §2) |

## Design rules

Design rules live in `CLAUDE.md` (code rules, binding) and `docs/ROADMAP.md` (architecture, state machines, performance discipline, milestone plan). `docs/HTTP2.md` is superseded except for its default limits table and DoS list, which Track B still uses.
