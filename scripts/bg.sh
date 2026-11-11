#!/bin/bash

cd "$(dirname "$0")/.."

ROOT_PATH="$PWD/Root" nohup "$(swift build -c release --show-bin-path)/SwiftWebServer" > server.log 2>&1 &
