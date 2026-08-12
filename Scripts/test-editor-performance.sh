#!/bin/zsh
set -euo pipefail

PERF_LOG=$(mktemp "${TMPDIR:-/tmp}/jelly-editor-performance.XXXXXX")
trap 'rm -f "$PERF_LOG"' EXIT

set +e
swift test -c release --filter BlockEditorPerformanceTests 2>&1 | tee "$PERF_LOG"
TEST_STATUS=$?
set -e
if (( TEST_STATUS != 0 )); then
  exit "$TEST_STATUS"
fi

if ! grep -q '^EDITOR_PERF|' "$PERF_LOG"; then
  echo "性能测试没有产生可验收的采样结果" >&2
  exit 3
fi

echo
echo "Jelly 编辑器性能结果（Release，单位 ms）"
printf '%-10s %-14s %10s %10s\n' "数据集" "阶段" "p95" "max"
awk -F'|' '/^EDITOR_PERF\|/ { printf "%-10s %-14s %10.3f %10.3f\n", $2, $3, $4, $5 }' "$PERF_LOG"
