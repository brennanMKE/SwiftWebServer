#!/bin/bash

# Testing WebSockets with Autobahn Test Suite
# https://github.com/crossbario/autobahn-testsuite

docker run -it --rm \
    -v "${PWD}/fuzzingserver.json:/config/fuzzingserver.json" \
    -v "${PWD}/reports:/reports" \
    -p 9000:9000 \
    -p 9001:9001 \
    --name fuzzingserver \
    crossbario/autobahn-testsuite
