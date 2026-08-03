#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR="$PROJECT_DIR/dist"
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-build.XXXXXX")
STAGING_APP="$STAGING_ROOT/个人月历.app"
STAGING_ARCHIVE="$STAGING_ROOT/个人月历.app.zip"
VERIFY_ROOT="$STAGING_ROOT/archive-verify"
CANDIDATE_PATH=""
BACKUP_PATH=""
ARCHIVE_PATH=""
PUBLICATION_PENDING=false
FORMAL_REPLACED=false

close_publication_transaction() {
  PUBLICATION_PENDING=false
  FORMAL_REPLACED=false
}

remove_formal_archive_for_rollback() {
  if [[ -n "$ARCHIVE_PATH" && ( -e "$ARCHIVE_PATH" || -L "$ARCHIVE_PATH" ) ]]; then
    if ! rm -f "$ARCHIVE_PATH"; then
      echo "Could not remove failed archive candidate from formal output path." >&2
      return 1
    fi
  fi
}

rollback_publication() {
  [[ "$PUBLICATION_PENDING" == true ]] || return 0
  trap '' HUP INT TERM

  if [[ "$FORMAL_REPLACED" != true ]]; then
    close_publication_transaction
    if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
      if ! rm -f "$BACKUP_PATH"; then
        echo "Could not remove redundant archive backup after interrupted publication." >&2
        return 1
      fi
      BACKUP_PATH=""
    fi
    return 0
  fi

  if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then
    if mv -f "$BACKUP_PATH" "$ARCHIVE_PATH"; then
      close_publication_transaction
      BACKUP_PATH=""
      return 0
    fi

    local preserved_backup_path="$BACKUP_PATH"
    BACKUP_PATH=""
    echo "Could not restore the prior archive after publication failure; prior archive preserved at: $preserved_backup_path" >&2
    if remove_formal_archive_for_rollback; then
      close_publication_transaction
    fi
    return 1
  fi

  if remove_formal_archive_for_rollback; then
    close_publication_transaction
    return 0
  fi
  return 1
}

cleanup() {
  trap '' HUP INT TERM
  if [[ "$PUBLICATION_PENDING" == true ]]; then
    rollback_publication || true
  fi
  if [[ -n "$CANDIDATE_PATH" && ( -e "$CANDIDATE_PATH" || -L "$CANDIDATE_PATH" ) ]]; then
    rm -f "$CANDIDATE_PATH" || true
  fi
  if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
    rm -f "$BACKUP_PATH" || true
  fi
  find "$STAGING_ROOT" -depth -delete || true
}

handle_signal() {
  local signal_name="$1"
  local exit_code="$2"

  trap '' HUP INT TERM
  echo "Received $signal_name during archive publication; rolling back pending output." >&2
  rollback_publication || true
  exit "$exit_code"
}

trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

cd "$PROJECT_DIR"
if [[ -L "$DIST_DIR" ]]; then
  echo "Refusing symlinked dist directory: $DIST_DIR" >&2
  exit 2
fi
swift build -c release --product PersonalCalendar
BIN_DIR=$(swift build -c release --show-bin-path)
if [[ -L "$DIST_DIR" ]]; then
  echo "Refusing symlinked dist directory: $DIST_DIR" >&2
  exit 2
fi
mkdir -p "$DIST_DIR"
DIST_REAL=$(cd "$DIST_DIR" && pwd -P)
[[ "$DIST_REAL" == "$PROJECT_DIR/dist" ]] || {
  echo "Unexpected physical dist path: $DIST_REAL" >&2
  exit 2
}

APP_DIR="$DIST_REAL/个人月历.app"
ARCHIVE_PATH="$DIST_REAL/个人月历.app.zip"
CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
[[ "$APP_DIR" == "$PROJECT_DIR/dist/个人月历.app" ]] || {
  echo "Unexpected app output path: $APP_DIR" >&2
  exit 2
}
[[ "$ARCHIVE_PATH" == "$PROJECT_DIR/dist/个人月历.app.zip" ]] || {
  echo "Unexpected archive output path: $ARCHIVE_PATH" >&2
  exit 2
}
if [[ -L "$ARCHIVE_PATH" || ( -e "$ARCHIVE_PATH" && ! -f "$ARCHIVE_PATH" ) ]]; then
  echo "Unexpected archive output target: $ARCHIVE_PATH" >&2
  exit 2
fi
CANDIDATE_PATH="$DIST_REAL/.个人月历.app.zip.candidate.$$"
BACKUP_PATH="$DIST_REAL/.个人月历.app.zip.backup.$$"
for temporary_archive_path in "$CANDIDATE_PATH" "$BACKUP_PATH"; do
  if [[ -e "$temporary_archive_path" || -L "$temporary_archive_path" ]]; then
    echo "Unexpected temporary archive target: $temporary_archive_path" >&2
    exit 2
  fi
done

verify_archive() {
  local archive_path="$1"
  local verify_root="$2"
  local extracted_app="$verify_root/个人月历.app"

  if [[ -e "$verify_root" || -L "$verify_root" ]]; then
    find "$verify_root" -depth -delete || return 1
  fi
  mkdir -p "$verify_root" || return 1
  ditto -x -k "$archive_path" "$verify_root" || return 1
  [[ -d "$extracted_app" ]] || {
    echo "Archive extraction did not contain an app bundle: $archive_path" >&2
    return 1
  }
  if xattr -lr "$extracted_app" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
    echo "Archive extraction contained FileProvider signing detritus." >&2
    return 1
  fi
  codesign --verify --deep --strict "$extracted_app"
}

cleanup_partial_launcher() {
  if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    if ! rm -rf "$APP_DIR"; then
      echo "Warning: could not clean partial local app copy; use $ARCHIVE_PATH." >&2
    fi
  fi
}

publish_local_launcher() {
  if ! rm -rf "$APP_DIR"; then
    echo "Warning: could not clear prior local app copy; skipping launcher and using $ARCHIVE_PATH." >&2
    return 0
  fi
  if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    echo "Warning: prior local app copy remains; skipping launcher and using $ARCHIVE_PATH." >&2
    return 0
  fi
  if ! ditto --norsrc "$STAGING_APP" "$APP_DIR"; then
    echo "Warning: could not publish local app copy; use $ARCHIVE_PATH." >&2
    cleanup_partial_launcher
    return 0
  fi
  if ! xattr -cr "$APP_DIR"; then
    echo "Warning: could not clear attributes from local app copy; use $ARCHIVE_PATH." >&2
    cleanup_partial_launcher
    return 0
  fi
  if ! codesign --verify --deep --strict "$APP_DIR"; then
    echo "Warning: local app copy was mutated after publication; use $ARCHIVE_PATH." >&2
    cleanup_partial_launcher
    return 0
  fi

  echo "$APP_DIR"
}

mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/PersonalCalendar" "$MACOS_DIR/PersonalCalendar"
cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/PersonalCalendar"
plutil -lint "$CONTENTS_DIR/Info.plist"
xattr -cr "$STAGING_APP"
codesign --force --deep --sign - "$STAGING_APP"
xattr -cr "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

ditto --norsrc -c -k --keepParent "$STAGING_APP" "$STAGING_ARCHIVE"
if ! verify_archive "$STAGING_ARCHIVE" "$VERIFY_ROOT"; then
  echo "Staged archive verification failed; archive was not published." >&2
  exit 1
fi
if ! mv "$STAGING_ARCHIVE" "$CANDIDATE_PATH"; then
  echo "Could not stage archive candidate in dist." >&2
  exit 1
fi
if ! verify_archive "$CANDIDATE_PATH" "$VERIFY_ROOT"; then
  echo "Archive candidate verification failed; archive was not published." >&2
  exit 1
fi
if [[ -f "$ARCHIVE_PATH" ]] && ! cp -p "$ARCHIVE_PATH" "$BACKUP_PATH"; then
  echo "Could not back up the prior archive; archive was not replaced." >&2
  exit 1
fi
PUBLICATION_PENDING=true
FORMAL_REPLACED=true
if ! mv -f "$CANDIDATE_PATH" "$ARCHIVE_PATH"; then
  echo "Could not atomically publish archive candidate." >&2
  exit 1
fi
CANDIDATE_PATH=""

if ! verify_archive "$ARCHIVE_PATH" "$VERIFY_ROOT"; then
  echo "Published archive verification failed; rolling back the formal archive path." >&2
  rollback_publication || true
  exit 1
fi
close_publication_transaction
if [[ -f "$BACKUP_PATH" ]] && ! rm -f "$BACKUP_PATH"; then
  echo "Could not remove archive backup after successful publication." >&2
  exit 1
fi
BACKUP_PATH=""

# The archive above is authoritative. A raw app copied into a Documents-backed
# workspace is a best-effort local launcher and is reported only after it
# independently clears attributes and passes strict signature verification.
publish_local_launcher
echo "$ARCHIVE_PATH"
