#!/bin/bash

cd "$(dirname "$0")/.."

echo "Building!"
#swift build -c release
swift build -c release --product SwiftWebServer
echo "Done"

find .build -name SwiftWebServer -type f -perm +111
