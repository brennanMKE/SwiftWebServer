#!/bin/bash

showLogs() {
  log show \
  --last 1m \
  --predicate '(category == "WebSocketsTestSuite") || (category == "HTTPServer")' \
  --style syslog \
  --debug \
  --info
}

runTestSuite() {
    swift run -c debug SwiftWebSocketsTestSuite
}

runTestSuite
showLogs
