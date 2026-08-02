#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-archive.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
VERIFY_ROOT="$TEMP_ROOT/verify"

cleanup() {
  find "$TEMP_ROOT" -depth -delete
}
trap cleanup EXIT

rsync -a \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude '.git' \
  "$PROJECT_DIR/" "$PROJECT_COPY/"

zsh "$PROJECT_COPY/Scripts/build-app.sh"

ARCHIVE="$PROJECT_COPY/dist/个人月历.app.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Expected stable app archive: $ARCHIVE" >&2
  exit 1
fi

mkdir -p "$VERIFY_ROOT"
ditto -x -k "$ARCHIVE" "$VERIFY_ROOT"
EXTRACTED_APP="$VERIFY_ROOT/个人月历.app"
if [[ ! -d "$EXTRACTED_APP" ]]; then
  echo "Archive did not contain 个人月历.app." >&2
  exit 1
fi
if xattr -lr "$EXTRACTED_APP" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
  echo "Archive extraction contained FileProvider signing detritus." >&2
  exit 1
fi
codesign --verify --deep --strict "$EXTRACTED_APP"
echo "Packaging archive regression passed; extracted app has a strict valid signature."
