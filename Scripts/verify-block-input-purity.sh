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

  local syntax_tree
  if ! syntax_tree=$(xcrun swiftc -frontend -dump-parse "$file" 2>&1); then
    fail "Task 8 source is not legal Swift: $file"
    printf '%s\n' "$syntax_tree" >&2
    return 1
  fi

  local json_tree
  if ! json_tree=$(xcrun swiftc -frontend -dump-parse -dump-ast-format json "$file" 2>&1); then
    fail "Task 8 source cannot expose import tokens: $file"
    printf '%s\n' "$json_tree" >&2
    return 1
  fi
  local item_count
  if ! item_count=$(printf '%s' "$json_tree" | plutil -extract items raw -); then
    fail "Task 8 import token output is not structured JSON: $file"
    return 1
  fi
  local item_index=0
  local start
  local module
  while [[ "$item_index" -lt "$item_count" ]]; do
    local kind
    if ! kind=$(printf '%s' "$json_tree" | plutil -extract "items.$item_index._kind" raw -); then
      fail "Task 8 import token is missing its kind: $file"
      return 1
    fi
    if [[ "$kind" != "import_decl" ]]; then
      item_index=$((item_index + 1))
      continue
    fi
    if ! start=$(printf '%s' "$json_tree" | plutil -extract "items.$item_index.range.start" raw -) ||
       ! module=$(printf '%s' "$json_tree" | plutil -extract "items.$item_index.module_path.0" raw -); then
      fail "Task 8 import token is missing its source position: $file"
      return 1
    fi
    case "$module" in
      Foundation|WorkspaceDomain) ;;
      *)
        fail "Forbidden import '$module' in $file"
        return 1
        ;;
    esac

    local expected="import $module"
    local expected_length=${#expected}
    local source_slice
    source_slice=$(LC_ALL=C tail -c +$((start + 1)) "$file" | head -c "$expected_length")
    local next_byte
    next_byte=$(LC_ALL=C dd if="$file" bs=1 skip=$((start + expected_length)) count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
    local previous_byte
    previous_byte=""
    if [[ "$start" -gt 0 ]]; then
      previous_byte=$(LC_ALL=C dd if="$file" bs=1 skip=$((start - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
    fi
    if [[ "$source_slice" != "$expected" || ( "$start" -gt 0 && "$previous_byte" != "0a" ) || ( -n "$next_byte" && "$next_byte" != "0a" ) ]]; then
      fail "Modified import '$module' in $file"
      return 1
    fi

    if [[ "$start" -gt 0 ]]; then
      local previous_line
      previous_line=$(head -c "$start" "$file" | sed -n '$p' | sed 's/^[[:space:]]*//')
      case "$previous_line" in
        @*)
          fail "Modified import '$module' in $file"
          return 1
          ;;
      esac
    fi
    item_index=$((item_index + 1))
  done

  if printf '%s\n' "$syntax_tree" | grep -E 'access_level=(public|open)([)[:space:]]|$)' >/dev/null; then
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

  printf 'public struct FixtureExport { public init() {} }\n' > "$fixture_root/WorkspaceDomainFixture.swift"
  xcrun swiftc \
    -emit-module \
    -enable-testing \
    -module-name WorkspaceDomain \
    "$fixture_root/WorkspaceDomainFixture.swift" \
    -emit-module-path "$fixture_root/WorkspaceDomain.swiftmodule"

  local modified_index=0
  local modified_import
  while IFS= read -r modified_import; do
    modified_index=$((modified_index + 1))
    mkdir -p "$fixture_root/modified-$modified_index"
    for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
      printf 'import Foundation\nstruct Fixture {}\n' > "$fixture_root/modified-$modified_index/$name"
    done
    printf '%b\n' "$modified_import" \
      >> "$fixture_root/modified-$modified_index/BlockInputReducer.swift"
    if ! xcrun swiftc \
      -frontend \
      -parse \
      "$fixture_root/modified-$modified_index/BlockInputReducer.swift" >/dev/null 2>&1; then
      fail "Self-test modified import is not legal Swift syntax: $modified_import"
    fi
    if scan_directory "$fixture_root/modified-$modified_index" >/dev/null 2>&1; then
      fail "Self-test accepted modified import: $modified_import"
    fi
  done <<'MODIFIED_IMPORTS'
public import WorkspaceDomain
package import WorkspaceDomain
internal import WorkspaceDomain
fileprivate import WorkspaceDomain
private import WorkspaceDomain
@_exported import WorkspaceDomain
@testable import WorkspaceDomain
@_implementationOnly import WorkspaceDomain
@preconcurrency import WorkspaceDomain
@_spi(FixtureSPI) import WorkspaceDomain
@_weakLinked import WorkspaceDomain
  import Foundation
import /* gap */ Foundation
@preconcurrency // keep\nimport WorkspaceDomain
MODIFIED_IMPORTS

  local index=0
  local invalid
  while IFS= read -r invalid; do
    index=$((index + 1))
    mkdir -p "$fixture_root/invalid-$index"
    for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
      printf 'import Foundation\nstruct Fixture {}\n' > "$fixture_root/invalid-$index/$name"
    done
    printf '%b\n' "$invalid" >> "$fixture_root/invalid-$index/BlockInputReducer.swift"
    if ! xcrun swiftc -frontend -parse "$fixture_root/invalid-$index/BlockInputReducer.swift" >/dev/null 2>&1; then
      fail "Self-test fixture is not legal Swift: $invalid"
    fi
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
import Foundation; import AppKit
public\nstruct Leaked {}
@MainActor\nnonisolated public\nfunc leaked() {}
public /* comment */ struct Leaked {}
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
