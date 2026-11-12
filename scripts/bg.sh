#!/bin/bash
# Runs the release server in the background with Root/http-config.json, logging to
# server.log. Extra arguments are passed on. Stop it with scripts/sigterm.sh.

cd "$(dirname "$0")/.."

swift build -c release -j 2 --product SwiftWebServer || exit 1
nohup "$(swift build -c release --show-bin-path)/SwiftWebServer" --config "$PWD/Root/http-config.json" "$@" \
    > server.log 2>&1 &
echo "SwiftWebServer started (pid $!), logging to server.log"
