#!/bin/sh
set -euo pipefail
if [[ -n "${ZSH_VERSION:-}" ]]; then
  setopt typesetsilent nonomatch
fi

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

  # This is byte-for-byte on purpose. The three Task 8 files are deliberately
  # closed to a two-import header; normalizing or tokenizing before this proof
  # would allow comments, modifiers, indentation, or a conditional import.
  local required_prefix=$'import Foundation\nimport WorkspaceDomain\n\n'
  local required_hex
  required_hex=$(printf '%s' "$required_prefix" | od -An -tx1 | tr -d '[:space:]')
  local actual_hex
  actual_hex=$(LC_ALL=C head -c "${#required_prefix}" "$file" | od -An -tx1 | tr -d '[:space:]')
  if [[ "$actual_hex" != "$required_hex" ]]; then
    fail "Task 8 source must begin with the exact two-import header: $file"
    return 1
  fi

  # These three files are a closed internal surface. Conservatively rejecting
  # tokens in comments and strings is intentional: it keeps inactive #if
  # branches out of scope without relying on the compiler's active AST.
  local remainder_start=$(( ${#required_prefix} + 1 ))
  if LC_ALL=C tail -c +"$remainder_start" "$file" | grep -Eq '(^|[^[:alnum:]_])import([^[:alnum:]_]|$)'; then
    fail "Forbidden import token after exact header: $file"
    return 1
  fi
  if LC_ALL=C grep -Eq '(^|[^[:alnum:]_])(public|open)([^[:alnum:]_]|$)' "$file"; then
    fail "Forbidden public/open token in Task 8 source: $file"
    return 1
  fi
}

scan_directory() {
  local directory="$1"
  local name
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    scan_file "$directory/$name" || return 1
  done

  local module_path="${BLOCK_INPUT_PURITY_MODULE_PATH:-}"
  if [[ -z "$module_path" ]]; then
    local candidate
    for candidate in .build/*/debug/Modules .build/*/release/Modules; do
      if [[ -f "$candidate/WorkspaceDomain.swiftmodule" ]]; then
        module_path="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$module_path" ]]; then
    fail "Missing WorkspaceDomain module needed to inspect Task 8 imports"
    return 1
  fi

  local sdk_path
  if ! sdk_path=$(xcrun --show-sdk-path); then
    fail "Cannot locate the Swift SDK for Task 8 purity inspection"
    return 1
  fi
  local expected_imports=$'Foundation\nWorkspaceDomain'
  local reducer="$directory/BlockInputReducer.swift"
  local selection="$directory/BlockEditorSelection.swift"
  local parser="$directory/BlockPasteParser.swift"
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    local primary_file="$directory/$name"
    local other_one
    local other_two
    case "$name" in
      BlockInputReducer.swift)
        other_one="$selection"
        other_two="$parser"
        ;;
      BlockEditorSelection.swift)
        other_one="$reducer"
        other_two="$parser"
        ;;
      BlockPasteParser.swift)
        other_one="$reducer"
        other_two="$selection"
        ;;
    esac
    local syntax_tree
    if ! syntax_tree=$(xcrun swiftc \
      -frontend -dump-ast -parse-as-library \
      -sdk "$sdk_path" -I "$module_path" \
      -primary-file "$primary_file" \
      "$other_one" "$other_two" 2>&1); then
      fail "Task 8 source is not legal Swift: $directory/$name"
      printf '%s\n' "$syntax_tree" >&2
      return 1
    fi

    # This is only a cross-check of the compiler's active view. The raw token
    # gate above is the safety proof for inactive #if branches; here, actual
    # import_decl nodes keep comments and strings out of the active check.
    local imports
    imports=$(printf '%s\n' "$syntax_tree" | sed -nE 's/^[[:space:]]*\(import_decl .* module="([^"]+)"\)$/\1/p')
    if [[ "$imports" != "$expected_imports" ]]; then
      fail "Task 8 imports must be exactly Foundation then WorkspaceDomain: $directory/$name"
      return 1
    fi

  done
  return 0
}

write_fixture_headers() {
  local directory="$1"
  mkdir -p "$directory"
  local name
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    printf 'import Foundation\nimport WorkspaceDomain\n\n' > "$directory/$name"
  done
}

append_fixture_declarations() {
  local directory="$1"
  printf 'struct BlockInputReducerFixture {}\n' >> "$directory/BlockInputReducer.swift"
  printf 'struct BlockEditorSelectionFixture {}\n' >> "$directory/BlockEditorSelection.swift"
  printf 'struct BlockPasteParserFixture {}\n' >> "$directory/BlockPasteParser.swift"
}

typecheck_fixture() {
  local directory="$1"
  local name
  for name in BlockInputReducer.swift BlockEditorSelection.swift BlockPasteParser.swift; do
    xcrun swiftc -typecheck -parse-as-library -package-name Jelly -I "$BLOCK_INPUT_PURITY_MODULE_PATH" \
      "$directory/$name" || return 1
  done
}

assert_fixture_is_rejected_at() {
  local directory="$1"
  local expected_stage="$2"
  local output
  if output=$(scan_directory "$directory" 2>&1); then
    fail "Self-test accepted forbidden fixture: $directory"
    return 1
  fi
  if [[ "$output" != *"$expected_stage"* ]]; then
    fail "Self-test rejected fixture at the wrong stage ($expected_stage): $output"
    return 1
  fi
}

self_test() {
  local fixture_root
  fixture_root=$(mktemp -d -t jelly-block-input-purity)
  trap "rm -rf '$fixture_root'" EXIT

  printf 'public struct FixtureExport { public init() {} }\n' > "$fixture_root/WorkspaceDomainFixture.swift"
  xcrun swiftc \
    -emit-module \
    -enable-testing \
    -module-name WorkspaceDomain \
    "$fixture_root/WorkspaceDomainFixture.swift" \
    -emit-module-path "$fixture_root/WorkspaceDomain.swiftmodule"

  local BLOCK_INPUT_PURITY_MODULE_PATH="$fixture_root"
  write_fixture_headers "$fixture_root/valid"
  append_fixture_declarations "$fixture_root/valid"
  printf 'let reopen = false\n' >> "$fixture_root/valid/BlockInputReducer.swift"
  typecheck_fixture "$fixture_root/valid"
  scan_directory "$fixture_root/valid"

  # These replace the header. They must typecheck but stop at raw-byte proof.
  local header_index=0
  local header_attack
  while IFS= read -r header_attack; do
    header_index=$((header_index + 1))
    local directory="$fixture_root/header-$header_index"
    write_fixture_headers "$directory"
    printf '%b\n' "$header_attack" > "$directory/BlockInputReducer.swift"
    append_fixture_declarations "$directory"
    if ! typecheck_fixture "$directory" >/dev/null 2>&1; then
      fail "Self-test header attack is not legal Swift: $header_attack"
      return 1
    fi
    assert_fixture_is_rejected_at "$directory" "exact two-import header" || return 1
  done <<'HEADER_ATTACKS'
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
@_exported\n// keep\nimport WorkspaceDomain
public\n// keep\nimport WorkspaceDomain
@preconcurrency\n\nimport WorkspaceDomain
HEADER_ATTACKS

  # These begin with the exact header, proving raw source import checking.
  local ast_import_index=0
  local ast_import_attack
  while IFS= read -r ast_import_attack; do
    ast_import_index=$((ast_import_index + 1))
    local directory="$fixture_root/ast-import-$ast_import_index"
    write_fixture_headers "$directory"
    printf '%b\n' "$ast_import_attack" >> "$directory/BlockInputReducer.swift"
    append_fixture_declarations "$directory"
    if ! typecheck_fixture "$directory" >/dev/null 2>&1; then
      fail "Self-test AST import attack is not legal Swift: $ast_import_attack"
      return 1
    fi
    assert_fixture_is_rejected_at "$directory" "Forbidden import token after exact header" || return 1
  done <<'AST_IMPORT_ATTACKS'
import AppKit
@preconcurrency import AppKit
import Foundation; import AppKit
#if os(macOS)\nimport AppKit\n#endif
#if os(iOS)\nimport AppKit\n#endif
#if canImport(UIKit)\nimport UIKit\n#endif
#if os(macOS)\nlet currentPlatform = true\n#else\nimport AppKit\n#endif
AST_IMPORT_ATTACKS

  # These begin with the exact header and prove public/open source checking.
  local public_index=0
  local public_attack
  while IFS= read -r public_attack; do
    public_index=$((public_index + 1))
    local directory="$fixture_root/public-$public_index"
    write_fixture_headers "$directory"
    printf '%b\n' "$public_attack" >> "$directory/BlockInputReducer.swift"
    append_fixture_declarations "$directory"
    if ! typecheck_fixture "$directory" >/dev/null 2>&1; then
      fail "Self-test public declaration attack is not legal Swift: $public_attack"
      return 1
    fi
    assert_fixture_is_rejected_at "$directory" "Forbidden public/open token" || return 1
  done <<'PUBLIC_DECLARATION_ATTACKS'
public struct Leaked {}
  public enum Leaked {}
@available(macOS 14, *) public final class Leaked {}
open class Leaked {}
final public class Leaked {}
@MainActor public func leaked() {}
public\nstruct Leaked {}
@MainActor\npublic\nfunc leaked() {}
public /* comment */ struct Leaked {}
public extension String {}
@available(macOS 14, *) public extension String {}
PUBLIC_DECLARATION_ATTACKS

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
