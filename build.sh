#!/bin/bash

echo "Building!"
swift build -c release
echo "Done"

find .build -name webserver
