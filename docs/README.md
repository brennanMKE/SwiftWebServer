# Docs

| Document | Purpose |
|---|---|
| [../README.md](../README.md) | What the server does, how to run it, configuration reference |
| [SERVER-COMPARISON.md](SERVER-COMPARISON.md) | New server vs nginx, Apache, Caddy, lighttpd, h2o (and the legacy server, until #0086) |
| [PROGRESS.md](PROGRESS.md) | Milestone status |
| [ROADMAP.md](ROADMAP.md) | Current architecture and milestone plan (authoritative) |
| [HTTP2.md](HTTP2.md) | Earlier HTTP/2 plan; superseded except its limits table and DoS list |
| [MIDDLEWARE.md](MIDDLEWARE.md) | Middleware builder, `RequestContext` and server components (#0083) |
| [PROJECT.md](PROJECT.md) | Historical: original description of the deleted legacy server |
| [TODO.md](TODO.md) | Historical: original to-do list; superseded by `issues/` |
| `notes/` | Technical findings (e.g. Span availability) |
| `spikes/` | Spike reports (e.g. QUIC) |
| `benchmarks/` | Per-milestone benchmark results |

Scripts live in `../scripts/` and can be run from any directory:

| Script | Purpose |
|---|---|
| `guarded.sh` | Run a command with a timeout and kill it if a system prompt appears (see AGENTS.md) |
| `bench-compare.sh` | Benchmark the new server against nginx, Apache, Caddy, lighttpd and h2o (loopback only) |
| `bench-baseline.sh` | Load and large-download memory benchmark of the shipped server against the M0 legacy baseline |
| `milestone-check.sh` | End-of-milestone debug and release tests plus micro benchmarks |
| `build.sh` | Release build of the `SwiftWebServer` executable |
| `run.sh` | Run the server in debug with `Root/http-config.json` (127.0.0.1:8080); extra arguments are passed on |
| `bg.sh` | Run the release server in the background with `Root/http-config.json`, logging to `server.log` |
| `sigint.sh` / `sigterm.sh` | Send SIGINT / SIGTERM to whatever listens on `PORT` (default 8080) |
| `list-ports.sh` | List ports used by running SwiftWebServer processes |
| `run-autobahn-*.sh` | Autobahn WebSocket test suite (needs Docker / `wstest`) |
| `commands.txt` | Handy manual curl checks |
