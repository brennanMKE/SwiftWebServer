#!/bin/bash

cd "$(dirname "$0")/.."

ROOT_PATH="$PWD/Root" exec swift run -c debug SwiftWebServer
