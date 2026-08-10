#!/bin/sh
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  return 1
}

scan_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    fail "Missing Task 8 source: $file"
    return 1
  fi

  local imports
  imports=$(sed -nE 's/^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*import[[:space:]]+([^[:space:];]+).*$/\3/p' "$file")
  local module
  while IFS= read -r module; do
    [[ -z "$module" ]] && continue
    case "$module" in
      Foundation|WorkspaceDomain) ;;
      *)
        fail "Forbidden import '$module' in $file"
        return 1
        ;;
    esac
  done <<< "$imports"

  if grep -En '^[[:space:]]*([^/]*[[:space:]])?(public|open)[[:space:]]+((final|nonisolated|static|override|required|convenience|mutating|nonmutating)[[:space:]]+)*(struct|class|enum|protocol|actor|func|var|let|init|subscript|typealias)([[:space:](<]|$)' "$file" >/dev/null; then
    fail "Public declaration in $file"
    return 1
  fi
  return 0
}

scan_directory() {
  local directory="$1"
  local name
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    scan_file "$directory/$name" || return 1
  done
  return 0
}

self_test() {
  local fixture_root
  fixture_root=$(mktemp -d -t jelly-block-input-purity)
  trap "rm -rf '$fixture_root'" EXIT

  mkdir -p "$fixture_root/valid"
  local name
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    printf 'import Foundation\nimport WorkspaceDomain\nstruct Fixture {}\n' > "$fixture_root/valid/$name"
  done
  scan_directory "$fixture_root/valid"

  local index=0
  local invalid
  while IFS= read -r invalid; do
    index=$((index + 1))
    mkdir -p "$fixture_root/invalid-$index"
    for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
      printf 'import Foundation\nstruct Fixture {}\n' > "$fixture_root/invalid-$index/$name"
    done
    printf '%s\n' "$invalid" >> "$fixture_root/invalid-$index/BlockInputReducer.swift"
    if scan_directory "$fixture_root/invalid-$index" >/dev/null 2>&1; then
      fail "Self-test accepted forbidden spelling: $invalid"
    fi
  done <<'INVALID_CASES'
import AppKit
  import SwiftUI
@preconcurrency import AppKit
import CalendarDomain
import Foundation.URLSession
public struct Leaked {}
  public enum Leaked {}
@available(macOS 14, *) public final class Leaked {}
open class Leaked {}
final public class Leaked {}
@MainActor nonisolated public func leaked() {}
INVALID_CASES

  printf '%s\n' "Block input purity self-test passed"
}

case "${1:-}" in
  --self-test)
    self_test
    ;;
  '')
    fail "Usage: $0 --self-test | <BlockEditor source directory>"
    ;;
  *)
    scan_directory "$1"
    printf '%s\n' "Block input purity scan passed: $1"
    ;;
esac
