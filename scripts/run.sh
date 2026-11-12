#!/bin/bash
# Runs the server (debug build) with Root/http-config.json: Root/Public on 127.0.0.1:8080.
# Extra arguments are passed on, e.g. `scripts/run.sh --port 9000`. Stop it with Ctrl-C,
# scripts/sigint.sh or scripts/sigterm.sh.

cd "$(dirname "$0")/.."

exec swift run -c debug SwiftWebServer --config "$PWD/Root/http-config.json" "$@"
