#!/bin/zsh
set -euo pipefail

TEST_LOG=$(mktemp "${TMPDIR:-/tmp}/personal-calendar-tests.XXXXXX")
trap 'rm -f "$TEST_LOG"' EXIT

set +e
swift test "$@" 2>&1 | tee "$TEST_LOG"
TEST_STATUS=$?
set -e
if (( TEST_STATUS != 0 )); then
  exit "$TEST_STATUS"
fi
if grep -q "No matching test cases were run" "$TEST_LOG"; then
  echo "Focused test filter matched zero tests" >&2
  exit 3
fi
