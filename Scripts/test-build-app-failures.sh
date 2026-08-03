#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-faults.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
FAKE_BIN="$TEMP_ROOT/fault-bin"
VERIFY_ROOT="$TEMP_ROOT/verify"
SOURCE_BIN_DIR=$(cd "$PROJECT_DIR" && swift build -c release --product PersonalCalendar >/dev/null && swift build -c release --show-bin-path)

cleanup() {
  find "$TEMP_ROOT" -depth -delete || true
}
trap cleanup EXIT

rsync -a --exclude '.build' --exclude 'dist' --exclude '.git' "$PROJECT_DIR/" "$PROJECT_COPY/"
PROJECT_COPY=$(cd "$PROJECT_COPY" && pwd -P)
mkdir -p "$FAKE_BIN"
for tool in ditto rm xattr codesign mv swift; do
  ln -s "$PROJECT_COPY/Scripts/test-build-app-fault-tool.sh" "$FAKE_BIN/$tool"
done

BUILD_SCRIPT="$PROJECT_COPY/Scripts/build-app.sh"
DIST_DIR="$PROJECT_COPY/dist"
APP_DIR="$DIST_DIR/个人月历.app"
ARCHIVE_PATH="$DIST_DIR/个人月历.app.zip"

assert_no_publish_residue() {
  if find "$DIST_DIR" -maxdepth 1 -name '.个人月历.app.zip.*' -print -quit | grep -q .; then
    print -u2 "Temporary archive publication residue remained in dist."
    exit 1
  fi
}

env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" zsh "$BUILD_SCRIPT" >/dev/null
archive_hash_before=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')

term_stdout="$TEMP_ROOT/term.stdout"
term_stderr="$TEMP_ROOT/term.stderr"
set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" \
  BUILD_APP_FAULT_DITTO_TERM_EXTRACT_SOURCE="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_exit_code=$?
set -e
[[ "$term_exit_code" -ne 0 ]] || {
  print -u2 "Expected formal archive verification TERM fault to fail the build."
  exit 1
}
archive_hash_after_term=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
[[ "$archive_hash_after_term" == "$archive_hash_before" ]] || {
  print -u2 "TERM during formal archive verification did not restore the prior archive bytes."
  exit 1
}
if grep -Fxq "$ARCHIVE_PATH" "$term_stdout"; then
  print -u2 "TERM during formal archive verification reported an authoritative archive output."
  exit 1
fi
assert_no_publish_residue

/bin/rm -f "$ARCHIVE_PATH"
set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" \
  BUILD_APP_FAULT_DITTO_TERM_EXTRACT_SOURCE="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_exit_code=$?
set -e
[[ "$term_exit_code" -ne 0 ]] || {
  print -u2 "Expected formal archive verification TERM fault without prior archive to fail."
  exit 1
}
[[ ! -e "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] || {
  print -u2 "TERM during formal archive verification left a candidate at the formal path."
  exit 1
}
if grep -Fxq "$ARCHIVE_PATH" "$term_stdout"; then
  print -u2 "TERM without prior archive reported an authoritative archive output."
  exit 1
fi
assert_no_publish_residue

env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" zsh "$BUILD_SCRIPT" >/dev/null
archive_hash_before=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')

sleep 2
set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" \
  BUILD_APP_FAULT_MV_TERM_CANDIDATE_DESTINATION="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_exit_code=$?
set -e
[[ "$term_exit_code" -ne 0 ]] || {
  print -u2 "Expected candidate publication TERM fault to fail the build."
  exit 1
}
archive_hash_after_candidate_term=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
[[ "$archive_hash_after_candidate_term" == "$archive_hash_before" ]] || {
  print -u2 "TERM after candidate publication did not restore the prior archive bytes."
  exit 1
}
if grep -Fxq "$ARCHIVE_PATH" "$term_stdout"; then
  print -u2 "TERM after candidate publication reported an authoritative archive output."
  exit 1
fi
assert_no_publish_residue

if rollback_failure_output=$(env \
  PATH="$FAKE_BIN:$PATH" \
  BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" \
  BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE="$ARCHIVE_PATH" \
  BUILD_APP_FAULT_MV_ROLLBACK_DESTINATION="$ARCHIVE_PATH" \
  zsh "$BUILD_SCRIPT" 2>&1); then
  print -u2 "Expected rollback rename fault to fail the build."
  exit 1
fi
backup_paths=()
while IFS= read -r candidate_backup_path; do
  [[ -n "$candidate_backup_path" ]] && backup_paths+=("$candidate_backup_path")
done < <(find "$DIST_DIR" -maxdepth 1 -type f -name '.个人月历.app.zip.backup.*' -print)
formal_archive_present=false
[[ -e "$ARCHIVE_PATH" || -L "$ARCHIVE_PATH" ]] && formal_archive_present=true
preserved_backup_path="${backup_paths[1]:-}"
backup_hash=""
if (( ${#backup_paths[@]} == 1 )); then
  backup_hash=$(shasum -a 256 "$preserved_backup_path" | awk '{print $1}')
fi
if [[ "$formal_archive_present" == true || ${#backup_paths[@]} -ne 1 || "$backup_hash" != "$archive_hash_before" ]] || ! print -r -- "$rollback_failure_output" | grep -Fq "$preserved_backup_path"; then
  print -u2 "Rollback rename fault did not preserve the prior archive outside the formal path."
  exit 1
fi
/bin/rm -f "$preserved_backup_path"
env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" zsh "$BUILD_SCRIPT" >/dev/null
archive_hash_before=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')

sleep 2
set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" \
  BUILD_APP_FAULT_RM_TERM_BACKUP=true \
  zsh "$BUILD_SCRIPT" >"$term_stdout" 2>"$term_stderr"
term_exit_code=$?
set -e
[[ "$term_exit_code" -ne 0 ]] || {
  print -u2 "Expected backup-cleanup TERM fault to fail the build."
  exit 1
}
formal_archive_present=false
[[ -f "$ARCHIVE_PATH" ]] && formal_archive_present=true
archive_hash_after_backup_term=""
if [[ "$formal_archive_present" == true ]]; then
  archive_hash_after_backup_term=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
fi
if [[ "$formal_archive_present" != true || "$archive_hash_after_backup_term" == "$archive_hash_before" ]]; then
  print -u2 "TERM after successful backup cleanup did not preserve the verified new archive."
  exit 1
fi
if grep -Fxq "$ARCHIVE_PATH" "$term_stdout"; then
  print -u2 "TERM after successful backup cleanup reported an authoritative archive output."
  exit 1
fi
assert_no_publish_residue

env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" zsh "$BUILD_SCRIPT" >/dev/null
archive_hash_before=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')

if env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE="$ARCHIVE_PATH" zsh "$BUILD_SCRIPT" >/dev/null; then
  print -u2 "Expected post-publication archive verification fault to fail the build."
  exit 1
fi
archive_hash_after=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
[[ "$archive_hash_after" == "$archive_hash_before" ]] || {
  print -u2 "Post-publication verification fault replaced the prior archive."
  exit 1
}
assert_no_publish_residue

/bin/rm -f "$ARCHIVE_PATH"
if env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" BUILD_APP_FAULT_DITTO_EXTRACT_SOURCE="$ARCHIVE_PATH" zsh "$BUILD_SCRIPT" >/dev/null; then
  print -u2 "Expected post-publication archive verification fault without prior archive to fail."
  exit 1
fi
[[ ! -e "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] || {
  print -u2 "Failed archive remained at the formal output path."
  exit 1
}
assert_no_publish_residue

env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" zsh "$BUILD_SCRIPT" >/dev/null

for fault_key in \
  BUILD_APP_FAULT_RM_TARGET \
  BUILD_APP_FAULT_DITTO_DESTINATION \
  BUILD_APP_FAULT_XATTR_TARGET \
  BUILD_APP_FAULT_CODESIGN_TARGET; do
  output=$(env PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR" "$fault_key=$APP_DIR" zsh "$BUILD_SCRIPT")
  print -r -- "$output" | grep -Fxq "$ARCHIVE_PATH" || {
    print -u2 "Launcher fault $fault_key did not report the authoritative archive."
    exit 1
  }
  if print -r -- "$output" | grep -Fxq "$APP_DIR"; then
    print -u2 "Launcher fault $fault_key reported an unverified app path."
    exit 1
  fi
  if [[ "$fault_key" != "BUILD_APP_FAULT_RM_TARGET" ]]; then
    [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]] || {
      print -u2 "Launcher fault $fault_key left a partial local app copy."
      exit 1
    }
  fi
  [[ -f "$ARCHIVE_PATH" ]] || {
    print -u2 "Launcher fault $fault_key removed the authoritative archive."
    exit 1
  }
done

mkdir -p "$VERIFY_ROOT"
ditto -x -k "$ARCHIVE_PATH" "$VERIFY_ROOT"
codesign --verify --deep --strict "$VERIFY_ROOT/个人月历.app"

print "Packaging fault-injection regressions passed."
