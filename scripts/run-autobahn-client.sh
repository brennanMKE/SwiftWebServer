#!/bin/bash

cd "$(dirname "$0")/.."

wstest -m fuzzingclient -s scripts/fuzzingclient.json
