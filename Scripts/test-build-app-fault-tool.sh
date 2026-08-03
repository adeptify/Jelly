#!/bin/zsh
set -euo pipefail

last_arg=${@: -1}

case "${0:t}" in
  ditto)
    if [[ "${BUILD_APP_FAULT_DITTO_TERM_EXTRACT_SOURCE:-}" == "${3:-}" ]]; then
      kill -TERM "$PPID"
      exit 143
    fi
    if [[ "${BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE:-}" == "${3:-}" ]]; then
      exit 1
    fi
    if [[ "${BUILD_APP_FAULT_DITTO_DESTINATION:-}" == "$last_arg" ]]; then
      mkdir -p "$last_arg/Contents"
      print -n partial > "$last_arg/Contents/partial"
      exit 1
    fi
    exec /usr/bin/ditto "$@"
    ;;
  rm)
    if [[
      "${BUILD_APP_FAULT_RM_TERM_BACKUP:-}" == true &&
      "$last_arg" == *.个人月历.app.zip.backup.*
    ]]; then
      /bin/rm "$@"
      kill -TERM "$PPID"
      exit 143
    fi
    if [[ "${BUILD_APP_FAULT_RM_TARGET:-}" == "$last_arg" ]]; then
      exit 1
    fi
    exec /bin/rm "$@"
    ;;
  xattr)
    if [[ "${BUILD_APP_FAULT_XATTR_TARGET:-}" == "$last_arg" ]]; then
      exit 1
    fi
    exec /usr/bin/xattr "$@"
    ;;
  codesign)
    if [[ "${BUILD_APP_FAULT_CODESIGN_TARGET:-}" == "$last_arg" ]]; then
      exit 1
    fi
    exec /usr/bin/codesign "$@"
    ;;
  mv)
    source_arg="${2:-}"
    if [[
      "${BUILD_APP_FAULT_MV_TERM_CANDIDATE_DESTINATION:-}" == "$last_arg" &&
      "$source_arg" == *.个人月历.app.zip.candidate.*
    ]]; then
      /bin/mv "$@"
      kill -TERM "$PPID"
      exit 143
    fi
    if [[
      "${BUILD_APP_FAULT_MV_ROLLBACK_DESTINATION:-}" == "$last_arg" &&
      "$source_arg" == *.个人月历.app.zip.backup.*
    ]]; then
      exit 1
    fi
    exec /bin/mv "$@"
    ;;
  swift)
    if [[ "${1:-}" == "build" ]]; then
      if [[ "$*" == *"--show-bin-path"* ]]; then
        [[ -n "${BUILD_APP_FAKE_SWIFT_BIN_DIR:-}" ]] || exit 2
        print "$BUILD_APP_FAKE_SWIFT_BIN_DIR"
      fi
      exit 0
    fi
    exec /usr/bin/swift "$@"
    ;;
  *)
    print -u2 "Unexpected fault-tool invocation: ${0:t}"
    exit 2
    ;;
esac
