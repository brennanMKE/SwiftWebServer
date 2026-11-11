#!/bin/bash
# Comprehensive end-of-milestone check.
#
#   scripts/milestone-check.sh M1
#
# 1. Debug build + full test suite.
# 2. Release build + full test suite (enables release-only assertions such as
#    zero-allocation checks).
# 3. Release micro benchmarks, written to docs/benchmarks/<milestone>-micro.md
#    with the load average, so results can be compared milestone to milestone.
# Every step runs through scripts/guarded.sh. Builds use -j 2 (see AGENTS.md).

set -o pipefail
cd "$(dirname "$0")/.."
M="${1:?usage: $0 <milestone, e.g. M1>}"
OUT="docs/benchmarks/${M}-micro.md"
LOG="${TMPDIR:-/tmp}/sws-milestone-${M}.log"
G=scripts/guarded.sh

step() { echo "== $*"; }
count() { grep -E "Test run with" "$1" | awk '{n+=$5} END{print n+0}'; }

step "debug build + tests"
$G -t 1800 -- swift test -j 2 > "$LOG.debug" 2>&1 || { tail -30 "$LOG.debug"; echo "FAIL: debug tests"; exit 1; }
DEBUG_N=$(count "$LOG.debug")

step "release build + tests"
$G -t 2400 -- swift test -c release -j 2 > "$LOG.release" 2>&1 || { tail -30 "$LOG.release"; echo "FAIL: release tests"; exit 1; }
RELEASE_N=$(count "$LOG.release")

step "release micro benchmarks"
$G -t 1200 -- swift build -c release -j 2 --product sws-bench > /dev/null 2>&1 || { echo "FAIL: release build"; exit 1; }
BIN="$(swift build -c release --show-bin-path)/sws-bench"
LOAD_BEFORE=$(uptime | sed 's/.*load averages*: //')
$G -t 1200 -- "$BIN" micro --iterations 300 > "$LOG.micro" 2>&1 || { tail -30 "$LOG.micro"; echo "FAIL: micro benchmarks"; exit 1; }
LOAD_AFTER=$(uptime | sed 's/.*load averages*: //')

{
  echo "# ${M} micro benchmarks"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M %Z')"
  echo "- Commit: $(git rev-parse --short HEAD)"
  echo "- Machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores"
  echo "- Load average before / after: ${LOAD_BEFORE} / ${LOAD_AFTER}"
  echo "- Tests: ${DEBUG_N} passed (debug), ${RELEASE_N} passed (release)"
  echo
  echo '```'
  cat "$LOG.micro"
  echo '```'
} > "$OUT"

echo "PASS: ${DEBUG_N} debug tests, ${RELEASE_N} release tests; benchmarks in ${OUT}"
