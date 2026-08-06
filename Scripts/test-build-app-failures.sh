#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-faults.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
FAKE_BIN="$TEMP_ROOT/fault-bin"
SOURCE_BIN_DIR=$(cd "$PROJECT_DIR" && swift build -c release --product PersonalCalendar >/dev/null && swift build -c release --show-bin-path)

cleanup() {
  find "$TEMP_ROOT" -depth -delete || true
}
trap cleanup EXIT

rsync -a --exclude '.build' --exclude 'dist' --exclude '.git' "$PROJECT_DIR/" "$PROJECT_COPY/"
PROJECT_COPY=$(cd "$PROJECT_COPY" && pwd -P)
mkdir -p "$FAKE_BIN"
for tool in ditto hdiutil rm xattr codesign mv swift; do
  ln -s "$PROJECT_COPY/Scripts/test-build-app-fault-tool.sh" "$FAKE_BIN/$tool"
done

BUILD_SCRIPT="$PROJECT_COPY/Scripts/build-app.sh"
DIST_DIR="$PROJECT_COPY/dist"
APP_DIR="$DIST_DIR/Jelly.app"
ARCHIVE_PATH="$DIST_DIR/Jelly.app.zip"
DMG_PATH="$DIST_DIR/Jelly.dmg"
COMMON_ENV=(PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR")

assert_no_publish_residue() {
  local residue
  residue=$(find "$DIST_DIR" -maxdepth 1 \( -name '.Jelly.app.zip.*' -o -name '.Jelly.dmg.*' \) -print)
  if [[ -n "$residue" ]]; then
    print -u2 "Temporary package publication residue remained in dist."
    print -u2 -- "$residue"
    exit 1
  fi
}

assert_pair_present() {
  [[ -f "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" && -f "$DMG_PATH" && ! -L "$DMG_PATH" ]] || {
    print -u2 "The authoritative ZIP/DMG pair is incomplete."
    exit 1
  }
}

pair_hashes() {
  print "$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}') $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
}

assert_pair_unchanged() {
  local expected="$1"
  assert_pair_present
  [[ "$(pair_hashes)" == "$expected" ]] || {
    print -u2 "A failed package candidate changed the authoritative pair."
    exit 1
  }
  assert_no_publish_residue
}

assert_single_fired_marker() {
  local marker_path="$1"
  [[ -f "$marker_path" && ! -L "$marker_path" ]] || {
    print -u2 "Expected a regular one-shot fault marker: $marker_path"
    exit 1
  }
  local marker_lines marker_bytes marker_content
  marker_lines=$(wc -l < "$marker_path" | tr -d '[:space:]')
  marker_bytes=$(wc -c < "$marker_path" | tr -d '[:space:]')
  marker_content=$(<"$marker_path")
  [[ "$marker_lines" == 1 && "$marker_bytes" == 6 && "$marker_content" == fired ]] || {
    print -u2 "Expected exactly one 'fired' record in fault marker: $marker_path"
    exit 1
  }
}

assert_formal_attach_sequence() {
  local state_file="$1"
  local formal_dmg="$2"
  local actual_sequence
  actual_sequence=$(awk -F '\t' -v source="$formal_dmg" \
    '$3 == source { print $4 }' "$state_file" | paste -sd ' ' -)
  [[ "$actual_sequence" == "1 2" ]] || {
    print -u2 "Expected formal DMG attach occurrences '1 2', got '$actual_sequence'."
    exit 1
  }
}

assert_single_detach_event() {
  local event_path="$1"
  local expected_source="$2"
  local expected_occurrence="$3"
  local expected_device="$4"
  [[ -f "$event_path" && ! -L "$event_path" ]] || {
    print -u2 "Expected a regular detach fault event file: $event_path"
    exit 1
  }
  local event_lines actual_event expected_event
  event_lines=$(wc -l < "$event_path" | tr -d '[:space:]')
  actual_event=$(<"$event_path")
  expected_event="$expected_source"$'\t'"$expected_occurrence"$'\t'"$expected_device"
  [[ "$event_lines" == 1 && "$actual_event" == "$expected_event" ]] || {
    print -u2 "Expected detach fault event '$expected_event', got '$actual_event'."
    exit 1
  }
}

assert_detach_fault_binds_actual_target() {
  local state_file="$TEMP_ROOT/detach-target-binding.state"
  local event_file="$TEMP_ROOT/detach-target-binding.event"
  local marker_file="$TEMP_ROOT/detach-target-binding.marker"
  local recorded_device="/dev/personal-calendar-recorded-test-device"
  local wrong_device="/dev/personal-calendar-wrong-test-device"
  local source="$TEMP_ROOT/formal-test.dmg"
  print -r -- "$recorded_device"$'\t'"$TEMP_ROOT/mount"$'\t'"$source"$'\t'"2" > "$state_file"

  set +e
  env "${COMMON_ENV[@]}" \
    BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$state_file" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE="$source" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE_OCCURRENCE=2 \
    BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER="$marker_file" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_EVENT_FILE="$event_file" \
    hdiutil detach "$wrong_device" >/dev/null 2>&1
  local wrong_status=$?
  set -e
  [[ "$wrong_status" -ne 0 ]]
  [[ ! -e "$event_file" && ! -e "$marker_file" ]] || {
    print -u2 "A detach fault fired for a device absent from the attach state."
    exit 1
  }

  set +e
  env "${COMMON_ENV[@]}" \
    BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$state_file" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE="$source" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE_OCCURRENCE=2 \
    BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER="$marker_file" \
    BUILD_APP_FAULT_HDIUTIL_DETACH_EVENT_FILE="$event_file" \
    hdiutil detach "$recorded_device" >/dev/null 2>&1
  local recorded_status=$?
  set -e
  [[ "$recorded_status" -ne 0 ]]
  assert_single_fired_marker "$marker_file"
  assert_single_detach_event "$event_file" "$source" 2 "$recorded_device"
}

assert_recorded_device_detached() {
  local state_file="$1"
  local device mount_point image_path source_occurrence
  local leaked=false
  while IFS=$'\t' read -r device mount_point image_path source_occurrence; do
    [[ -n "$device" && -n "$image_path" && "$source_occurrence" == <-> ]] || {
      print -u2 "The attach fault recorded an incomplete device/image/occurrence identity."
      exit 1
    }
    if /usr/bin/hdiutil info | grep -Fq -- "$device" || \
      /usr/bin/hdiutil info | grep -Fq -- "$image_path" || \
      [[ -n "$mount_point" && -d "$mount_point" ]]; then
      /usr/bin/hdiutil detach -force "$device" >/dev/null 2>&1 || true
      print -u2 "A failed DMG verification left its image mounted: device=$device image=$image_path"
      leaked=true
    fi
  done < "$state_file"
  [[ "$leaked" == false ]] || exit 1
}

assert_detach_fault_binds_actual_target

env "${COMMON_ENV[@]}" zsh "$BUILD_SCRIPT" >/dev/null
assert_pair_present
baseline_hashes=$(pair_hashes)

# A DMG creation failure occurs before either candidate reaches dist.
if env "${COMMON_ENV[@]}" BUILD_APP_FAULT_HDIUTIL_CREATE=true zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected staged DMG creation failure."
  exit 1
fi
assert_pair_unchanged "$baseline_hashes"

# Every hidden candidate validation branch must fail before publication while
# preserving the exact prior pair and removing all temporary candidate files.
if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE_CONTAINS='.Jelly.app.zip.candidate.' \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/candidate-zip-extract-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected candidate ZIP extraction verification failure."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/candidate-zip-extract-fired"
assert_pair_unchanged "$baseline_hashes"

if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_CODESIGN_TARGET_CONTAINS='zip-verify-candidate/Jelly.app' \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/candidate-zip-signature-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected candidate ZIP signature verification failure."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/candidate-zip-signature-fired"
assert_pair_unchanged "$baseline_hashes"

if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_ATTACH_SOURCE_CONTAINS='.Jelly.dmg.candidate.' \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/candidate-dmg-attach-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected candidate DMG attach verification failure."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/candidate-dmg-attach-fired"
assert_pair_unchanged "$baseline_hashes"

# The archive regression owns its attachment cleanup. Inject mount metadata
# loss and a first detach failure into an already-built isolated pair so the
# test proves cleanup by the recorded device without rebuilding another pair.
archive_mount_state="$TEMP_ROOT/archive-mount-parse.state"
if env "${COMMON_ENV[@]}" \
  BUILD_APP_ARCHIVE_EXISTING_PROJECT="$PROJECT_COPY" \
  BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$archive_mount_state" \
  BUILD_APP_FAULT_HDIUTIL_OMIT_MOUNT_POINT_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/archive-mount-parse-fired" \
  zsh "$PROJECT_COPY/Scripts/test-build-app-archive.sh" >/dev/null 2>&1; then
  print -u2 "Expected archive verification mount-point metadata failure."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/archive-mount-parse-fired"
assert_recorded_device_detached "$archive_mount_state"
assert_pair_unchanged "$baseline_hashes"

archive_detach_state="$TEMP_ROOT/archive-detach-retry.state"
if env "${COMMON_ENV[@]}" \
  BUILD_APP_ARCHIVE_EXISTING_PROJECT="$PROJECT_COPY" \
  BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$archive_detach_state" \
  BUILD_APP_FAULT_HDIUTIL_DETACH_ONCE_AFTER_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/archive-detach-retry-fired" \
  zsh "$PROJECT_COPY/Scripts/test-build-app-archive.sh" >/dev/null 2>&1; then
  print -u2 "Expected archive verification's first detach to fail."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/archive-detach-retry-fired"
assert_recorded_device_detached "$archive_detach_state"
assert_pair_unchanged "$baseline_hashes"

# Trigger missing mount metadata only when verifying the published formal DMG.
# Rollback must restore both exact prior bytes and cleanup every attach made
# before and during rollback verification.
published_mount_state="$TEMP_ROOT/published-mount-parse.state"
if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$published_mount_state" \
  BUILD_APP_FAULT_HDIUTIL_OMIT_MOUNT_POINT_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/published-mount-parse-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected published DMG mount-point metadata failure."
  exit 1
fi
assert_recorded_device_detached "$published_mount_state"
assert_pair_unchanged "$baseline_hashes"

# Force the first explicit rollback to fail before verification. EXIT cleanup
# then detaches the failed published attach, retries rollback, and verifies the
# restored formal DMG. Make that rollback attachment's first detach fail: the
# restored content is still valid, so the exact pair must remain authoritative
# and cleanup's final detach pass must remove the newly tracked attachment.
rollback_detach_state="$TEMP_ROOT/rollback-detach-retry.state"
rollback_published_marker="$TEMP_ROOT/rollback-published-mount-parse-fired"
rollback_remove_marker="$TEMP_ROOT/rollback-remove-fired"
rollback_detach_marker="$TEMP_ROOT/rollback-detach-fired"
rollback_detach_event="$TEMP_ROOT/rollback-detach.event"
if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$rollback_detach_state" \
  BUILD_APP_FAULT_HDIUTIL_OMIT_MOUNT_POINT_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$rollback_published_marker" \
  BUILD_APP_FAULT_RM_ONCE_TARGET="$ARCHIVE_PATH" \
  BUILD_APP_FAULT_RM_ONCE_MARKER="$rollback_remove_marker" \
  BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_HDIUTIL_DETACH_SOURCE_OCCURRENCE=2 \
  BUILD_APP_FAULT_HDIUTIL_DETACH_OCCURRENCE_MARKER="$rollback_detach_marker" \
  BUILD_APP_FAULT_HDIUTIL_DETACH_EVENT_FILE="$rollback_detach_event" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected published verification and rollback DMG detach failure."
  exit 1
fi
assert_single_fired_marker "$rollback_published_marker"
assert_single_fired_marker "$rollback_remove_marker"
assert_single_fired_marker "$rollback_detach_marker"
rollback_detach_device=$(awk -F '\t' -v source="$DMG_PATH" '$3 == source && $4 == 2 { print $1; exit }' "$rollback_detach_state")
[[ -n "$rollback_detach_device" ]]
assert_single_detach_event "$rollback_detach_event" "$DMG_PATH" 2 "$rollback_detach_device"
assert_formal_attach_sequence "$rollback_detach_state" "$DMG_PATH"
assert_recorded_device_detached "$rollback_detach_state"
assert_pair_unchanged "$baseline_hashes"

# Trigger the first detach failure only after the published formal DMG attach.
# The failed published attachment and rollback verification attachment must not
# overwrite one another's cleanup identity.
published_detach_state="$TEMP_ROOT/published-detach-retry.state"
if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_STATE_FILE="$published_detach_state" \
  BUILD_APP_FAULT_HDIUTIL_DETACH_ONCE_AFTER_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/published-detach-retry-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected the published DMG's first detach to fail verification."
  exit 1
fi
assert_recorded_device_detached "$published_detach_state"
assert_pair_unchanged "$baseline_hashes"

# Interrupt after ZIP replacement but before DMG replacement: both old bytes return.
term_stdout="$TEMP_ROOT/term.stdout"
term_stderr="$TEMP_ROOT/term.stderr"
set +e
env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_MV_TERM_CANDIDATE_DESTINATION="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_status=$?
set -e
[[ "$term_status" -ne 0 ]] || {
  print -u2 "Expected interrupted ZIP publication to fail."
  exit 1
}
assert_pair_unchanged "$baseline_hashes"
if grep -Fxq "$ARCHIVE_PATH" "$term_stdout" || grep -Fxq "$DMG_PATH" "$term_stdout"; then
  print -u2 "Interrupted publication reported an authoritative package."
  exit 1
fi

# Both package members can be strictly signed yet still carry different code
# identities. Published-pair verification must detect that mismatch and restore
# the exact prior pair.
mismatch_root="$TEMP_ROOT/mismatched-dmg"
mismatch_extract="$mismatch_root/extract"
mismatch_source="$mismatch_root/source"
mismatch_dmg="$mismatch_root/Jelly-mismatched.dmg"
mkdir -p "$mismatch_extract" "$mismatch_source"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$mismatch_extract"
mismatch_app="$mismatch_extract/Jelly.app"
/usr/bin/plutil -replace CFBundleVersion -string 2 "$mismatch_app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$mismatch_app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$mismatch_app"
/usr/bin/ditto --norsrc "$mismatch_app" "$mismatch_source/Jelly.app"
ln -s /Applications "$mismatch_source/Applications"
/usr/bin/hdiutil create -volname "Jelly" -srcfolder "$mismatch_source" -ov -format UDZO "$mismatch_dmg" >/dev/null

if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_MATCH_CONTAINS='.Jelly.dmg.candidate.' \
  BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_SOURCE="$mismatch_dmg" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/candidate-dmg-content-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected candidate DMG content verification failure."
  exit 1
fi
assert_single_fired_marker "$TEMP_ROOT/candidate-dmg-content-fired"
assert_pair_unchanged "$baseline_hashes"

if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_MATCH="$DMG_PATH" \
  BUILD_APP_FAULT_HDIUTIL_SUBSTITUTE_SOURCE="$mismatch_dmg" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/dmg-substitute-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected mismatched published ZIP/DMG identities to fail."
  exit 1
fi
assert_pair_unchanged "$baseline_hashes"

# Failure while verifying the published DMG restores the prior pair.
if env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_HDIUTIL_ATTACH_SOURCE="$DMG_PATH" \
  BUILD_APP_FAULT_ONCE_MARKER="$TEMP_ROOT/dmg-attach-fired" \
  zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected published DMG verification failure."
  exit 1
fi
assert_pair_unchanged "$baseline_hashes"

# The first publication has no prior outputs; interruption leaves neither format.
/bin/rm -f "$ARCHIVE_PATH" "$DMG_PATH"
set +e
env "${COMMON_ENV[@]}" \
  BUILD_APP_FAULT_MV_TERM_CANDIDATE_DESTINATION="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_status=$?
set -e
[[ "$term_status" -ne 0 ]]
[[ ! -e "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" && ! -e "$DMG_PATH" && ! -L "$DMG_PATH" ]] || {
  print -u2 "Interrupted first publication left an incomplete pair."
  exit 1
}
assert_no_publish_residue

env "${COMMON_ENV[@]}" zsh "$BUILD_SCRIPT" >/dev/null
baseline_hashes=$(pair_hashes)

# A best-effort launcher failure must never remove or hide the verified pair.
for fault_key in \
  BUILD_APP_FAULT_RM_TARGET \
  BUILD_APP_FAULT_DITTO_DESTINATION \
  BUILD_APP_FAULT_XATTR_TARGET \
  BUILD_APP_FAULT_CODESIGN_TARGET; do
  output=$(env "${COMMON_ENV[@]}" "$fault_key=$APP_DIR" zsh "$BUILD_SCRIPT")
  print -r -- "$output" | grep -Fxq "$ARCHIVE_PATH"
  print -r -- "$output" | grep -Fxq "$DMG_PATH"
  assert_pair_present
  assert_no_publish_residue
done

print "Packaging pair fault-injection regressions passed."
