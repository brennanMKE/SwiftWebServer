# Docs

| Document | Purpose |
|---|---|
| [ROADMAP.md](ROADMAP.md) | Current architecture and milestone plan (authoritative) |
| [HTTP2.md](HTTP2.md) | Earlier HTTP/2 plan; superseded except its limits table and DoS list |
| [MIDDLEWARE.md](MIDDLEWARE.md) | Early middleware notes; superseded by ROADMAP §5.2 |
| [PROJECT.md](PROJECT.md) | Original project description (legacy server) |
| [TODO.md](TODO.md) | Original to-do list; superseded by `issues/` |
| `notes/` | Technical findings (e.g. Span availability) |
| `spikes/` | Spike reports (e.g. QUIC) |
| `benchmarks/` | Per-milestone benchmark results |

Scripts live in `../scripts/` and can be run from any directory:

| Script | Purpose |
|---|---|
| `build.sh` | Release build of the `SwiftWebServer` executable |
| `run.sh` | Run the server in debug, serving `Root/` |
| `bg.sh` | Run the release server in the background, logging to `server.log` |
| `sigint.sh` / `sigterm.sh` | Send SIGINT / SIGTERM to whatever listens on port 8080 |
| `list-ports.sh` | List ports used by running SwiftWebServer processes |
| `run-autobahn-*.sh` | Autobahn WebSocket test suite (needs Docker / `wstest`) |
| `commands.txt` | Handy manual curl checks |
