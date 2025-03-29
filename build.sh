#!/bin/bash

echo "Building!"
#swift build -c release
swift build -c release --product webserver
echo "Done"

find .build -name webserver
