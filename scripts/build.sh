#!/bin/bash
# Release build of the SwiftWebServer executable.

cd "$(dirname "$0")/.."

echo "Building!"
swift build -c release -j 2 --product SwiftWebServer || exit 1
echo "Done"

echo "$(swift build -c release --show-bin-path)/SwiftWebServer"
