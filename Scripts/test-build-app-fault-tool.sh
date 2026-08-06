#!/bin/zsh
set -euo pipefail

last_arg=${@: -1}

case "${0:t}" in
  ditto)
    if [[ "${BUILD_APP_FAULT_DITTO_TERM_EXTRACT_SOURCE:-}" == "${3:-}" ]]; then
      kill -TERM "$PPID"
      exit 143
    fi
    if [[ "${BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE:-}" == "${3:-}" || \
      ( -n "${BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE_CONTAINS:-}" && \
        "${3:-}" == *"${BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE_CONTAINS}"* ) ]]; then
      if [[ -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]]; then
        exit 1
      fi
      if [[ ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ]]; then
        print -r -- fired > "$BUILD_APP_FAULT_ONCE_MARKER"
        exit 1
      fi
    fi
    if [[ "${BUILD_APP_FAULT_DITTO_DESTINATION:-}" == "$last_arg" ]]; then
      mkdir -p "$last_arg/Contents"
      print -n partial > "$last_arg/Contents/partial"
      exit 1
    fi
    exec /usr/bin/ditto "$@"
    ;;
  hdiutil)
    if [[ "${1:-}" == "create" && (
      "${BUILD_APP_FAULT_HDIUTIL_CREATE:-}" == true ||
      "${BUILD_APP_FAULT_HDIUTIL_CREATE_DESTINATION:-}" == "$last_arg"
    ) ]]; then
      exit 1
    fi
    if [[ "${1:-}" == "attach" && "${BUILD_APP_FAULT_HDIUTIL_TERM_ATTACH_SOURCE:-}" == "$last_arg" ]]; then
      kill -TERM "$PPID"
      exit 143
    fi
    if [[ "${1:-}" == "attach" && \
      ( "${BUILD_APP_FAULT_HDIUTIL_ATTACH_SOURCE:-}" == "$last_arg" || \
        ( -n "${BUILD_APP_FAULT_HDIUTIL_ATTACH_SOURCE_CONTAINS:-}" && \
          "$last_arg" == *"${BUILD_APP_FAULT_HDIUTIL_ATTACH_SOURCE_CONTAINS}"* ) ) ]]; then
      if [[ -n "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]]; then
        if [[ ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ]]; then
          print -r -- fired > "$BUILD_APP_FAULT_ONCE_MARKER"
          exit 1
        fi
      else
        exit 1
      fi
    fi
    if [[ "${1:-}" == "attach" && -n "${BUILD_APP_FAULT_HDIUTIL_STATE_FILE:-}" ]]; then
      attach_plist=$(mktemp "${TMPDIR:-/tmp}/personal-calendar-fault-attach.XXXXXX")
      set +e
      /usr/bin/hdiutil "$@" > "$attach_plist"
      attach_status=$?
      set -e
      if [[ "$attach_status" -ne 0 ]]; then
        /bin/rm -f "$attach_plist"
        exit "$attach_status"
      fi
      recorded_device=""
      recorded_mount=""
      for index in {0..20}; do
        [[ -n "$recorded_device" ]] || recorded_device=$(plutil -extract "system-entities.$index.dev-entry" raw -o - "$attach_plist" 2>/dev/null || true)
        [[ -n "$recorded_mount" ]] || recorded_mount=$(plutil -extract "system-entities.$index.mount-point" raw -o - "$attach_plist" 2>/dev/null || true)
      done
      prior_source_occurrences=$(awk -F '\t' -v source="$last_arg" \
        '$3 == source { count += 1 } END { print count + 0 }' \
        "$BUILD_APP_FAULT_HDIUTIL_STATE_FILE" 2>/dev/null || print 0)
      recorded_source_occurrence=$((prior_source_occurrences + 1))
      print -r -- "$recorded_device"$'\t'"$recorded_mount"$'\t'"$last_arg"$'\t'"$recorded_source_occurrence" >> "$BUILD_APP_FAULT_HDIUTIL_STATE_FILE"
      if [[ ( "${BUILD_APP_FAULT_HDIUTIL_OMIT_MOUNT_POINT_ONCE:-}" == true || \
          "${BUILD_APP_FAULT_HDIUTIL_OMIT_MOUNT_POINT_SOURCE:-}" == "$last_arg" ) && \
        ( -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" || ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ) ]]; then
        [[ -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]] || print -r -- fired >> "$BUILD_APP_FAULT_ONCE_MARKER"
        for index in {0..20}; do
          plutil -remove "system-entities.$index.mount-point" "$attach_plist" 2>/dev/null || true
        done
      fi
      /bin/cat "$attach_plist"
      /bin/rm -f "$attach_plist"
      exit 0
    fi
    if [[ "${1:-}" == "attach" && \
      ( "${BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_MATCH:-}" == "$last_arg" || \
        ( -n "${BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_MATCH_CONTAINS:-}" && \
          "$last_arg" == *"${BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_MATCH_CONTAINS}"* ) ) && \
      -n "${BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_SOURCE:-}" ]]; then
      if [[ -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" || ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ]]; then
        if [[ -n "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]]; then
          print -r -- fired > "$BUILD_APP_FAULT_ONCE_MARKER"
        fi
        replacement="$BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_SOURCE"
        exec /usr/bin/hdiutil "${@:1:$#-1}" "$replacement"
      fi
    fi
    recorded_attach_device=""
    recorded_attach_mount=""
    recorded_attach_source=""
    recorded_attach_source_occurrence=0
    if [[ "${1:-}" == "detach" && -n "${BUILD_APP_FAULT_HDIUTIL_STATE_FILE:-}" && \
      -f "$BUILD_APP_FAULT_HDIUTIL_STATE_FILE" ]]; then
      recorded_attach_row=$(awk -F '\t' -v target="$last_arg" \
        '$1 == target || $2 == target { row = $0 } END { print row }' \
        "$BUILD_APP_FAULT_HDIUTIL_STATE_FILE")
      if [[ -n "$recorded_attach_row" ]]; then
        IFS=$'\t' read -r recorded_attach_device recorded_attach_mount \
          recorded_attach_source recorded_attach_source_occurrence <<< "$recorded_attach_row"
      fi
    fi
    detach_source_occurrence_fault=false
    if [[ -n "${BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE:-}" && \
      "${BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE:-}" == "$recorded_attach_source" && \
      -n "${BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE_OCCURRENCE:-}" && \
      "${BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE_OCCURRENCE:-}" == "$recorded_attach_source_occurrence" && \
      ( -z "${BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER:-}" || \
        ! -e "$BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER" ) ]]; then
      detach_source_occurrence_fault=true
    fi
    if [[ "${1:-}" == "detach" && \
      "$detach_source_occurrence_fault" == true ]]; then
      detach_event_file="${BUILD_APP_FAULT_HDIUTIL_DETACH_EVENT_FILE:-}"
      if [[ -n "$detach_event_file" ]]; then
        if [[ -L "$detach_event_file" || ( -e "$detach_event_file" && ! -f "$detach_event_file" ) ]]; then
          print -u2 "Refusing non-regular detach fault event file: $detach_event_file"
          exit 2
        fi
        print -r -- "$recorded_attach_source"$'\t'"$recorded_attach_source_occurrence"$'\t'"$recorded_attach_device" >> "$detach_event_file"
      fi
      [[ -z "${BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER:-}" ]] || \
        print -r -- fired >> "$BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER"
      exit 1
    fi
    if [[ "${1:-}" == "detach" && \
      ( "${BUILD_APP_FAULT_HDIUTIL_DETACH_ONCE:-}" == true || \
        ( -n "${BUILD_APP_FAULT_HDIUTIL_DETACH_ONCE_AFTER_SOURCE:-}" && \
          "${BUILD_APP_FAULT_HDIUTIL_DETACH_ONCE_AFTER_SOURCE:-}" == "$recorded_attach_source" ) ) && \
      ( -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" || ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ) ]]; then
      [[ -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]] || print -r -- fired > "$BUILD_APP_FAULT_ONCE_MARKER"
      exit 1
    fi
    exec /usr/bin/hdiutil "$@"
    ;;
  rm)
    if [[
      "${BUILD_APP_FAULT_RM_TERM_BACKUP:-}" == true &&
      "$last_arg" == *.Jelly.app.zip.backup.*
    ]]; then
      /bin/rm "$@"
      kill -TERM "$PPID"
      exit 143
    fi
    if [[ "${BUILD_APP_FAULT_RM_ONCE_TARGET:-}" == "$last_arg" && \
      ( -z "${BUILD_APP_FAULT_RM_ONCE_MARKER:-}" || \
        ! -e "$BUILD_APP_FAULT_RM_ONCE_MARKER" ) ]]; then
      [[ -z "${BUILD_APP_FAULT_RM_ONCE_MARKER:-}" ]] || \
        print -r -- fired >> "$BUILD_APP_FAULT_RM_ONCE_MARKER"
      exit 1
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
    if [[ "${BUILD_APP_FAULT_CODESIGN_TARGET:-}" == "$last_arg" || \
      ( -n "${BUILD_APP_FAULT_CODESIGN_TARGET_CONTAINS:-}" && \
        "$last_arg" == *"${BUILD_APP_FAULT_CODESIGN_TARGET_CONTAINS}"* ) ]]; then
      if [[ -z "${BUILD_APP_FAULT_ONCE_MARKER:-}" ]]; then
        exit 1
      fi
      if [[ ! -e "$BUILD_APP_FAULT_ONCE_MARKER" ]]; then
        print -r -- fired > "$BUILD_APP_FAULT_ONCE_MARKER"
        exit 1
      fi
    fi
    exec /usr/bin/codesign "$@"
    ;;
  mv)
    source_arg="${2:-}"
    if [[
      "${BUILD_APP_FAULT_MV_TERM_CANDIDATE_DESTINATION:-}" == "$last_arg" &&
      "$source_arg" == *.Jelly.*.candidate.*
    ]]; then
      /bin/mv "$@"
      kill -TERM "$PPID"
      exit 143
    fi
    if [[
      "${BUILD_APP_FAULT_MV_ROLLBACK_DESTINATION:-}" == "$last_arg" &&
      "$source_arg" == *.Jelly.app.zip.backup.*
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
