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

  local canonical_source
  if ! canonical_source=$(xcrun swift-format format "$file"); then
    fail "Task 8 source cannot be parsed by swift-format: $file"
    return 1
  fi

  local syntax_tree
  if ! syntax_tree=$(printf '%s\n' "$canonical_source" | xcrun swiftc -frontend -dump-parse - 2>&1); then
    fail "Task 8 source is not legal Swift: $file"
    printf '%s\n' "$syntax_tree" >&2
    return 1
  fi

  local imports
  imports=$(printf '%s\n' "$syntax_tree" | sed -nE 's/.*\(import_decl .* range=\[[^]]*:[0-9]+:([0-9]+) - .* module="([^"]+)".*/\1|\2/p')
  local column
  local module
  while IFS='|' read -r column module; do
    [[ -z "$module" ]] && continue
    if [[ "$column" -ne 1 ]]; then
      fail "Modified import '$module' in $file"
      return 1
    fi
    case "$module" in
      Foundation|WorkspaceDomain) ;;
      *)
        fail "Forbidden import '$module' in $file"
        return 1
        ;;
    esac
  done <<< "$imports"

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
    printf '%s\n' "$modified_import" \
      >> "$fixture_root/modified-$modified_index/BlockInputReducer.swift"
    if ! xcrun swiftc \
      -typecheck \
      -package-name Jelly \
      -I "$fixture_root" \
      "$fixture_root/modified-$modified_index/BlockInputReducer.swift" >/dev/null 2>&1; then
      fail "Self-test modified import is not legal Swift: $modified_import"
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
