#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-package.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
SENTINEL_DIR="$TEMP_ROOT/sentinel"
SENTINEL_APP="$SENTINEL_DIR/个人月历.app"
SENTINEL_FILE="$SENTINEL_APP/Contents/sentinel.bin"
SENTINEL_ARCHIVE="$SENTINEL_DIR/个人月历.app.zip"

cleanup() {
  find "$TEMP_ROOT" -depth -delete
}
trap cleanup EXIT

rsync -a \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude '.git' \
  "$PROJECT_DIR/" "$PROJECT_COPY/"
mkdir -p "$SENTINEL_APP/Contents"
print -n "sentinel app must survive symlink rejection" > "$SENTINEL_FILE"
print -n "sentinel archive must survive symlink rejection" > "$SENTINEL_ARCHIVE"
APP_BEFORE_HASH=$(shasum -a 256 "$SENTINEL_FILE" | awk '{print $1}')
ARCHIVE_BEFORE_HASH=$(shasum -a 256 "$SENTINEL_ARCHIVE" | awk '{print $1}')

ln -s "$SENTINEL_DIR" "$PROJECT_COPY/dist"

set +e
zsh "$PROJECT_COPY/Scripts/build-app.sh"
STATUS=$?
set -e

if [[ $STATUS -ne 2 ]]; then
  echo "Expected symlinked dist rejection with exit 2, got $STATUS" >&2
  exit 1
fi
APP_AFTER_HASH=$(shasum -a 256 "$SENTINEL_FILE" | awk '{print $1}')
ARCHIVE_AFTER_HASH=$(shasum -a 256 "$SENTINEL_ARCHIVE" | awk '{print $1}')
if [[ "$APP_BEFORE_HASH" != "$APP_AFTER_HASH" || "$ARCHIVE_BEFORE_HASH" != "$ARCHIVE_AFTER_HASH" ]]; then
  echo "Sentinel app or archive changed despite symlink rejection." >&2
  exit 1
fi
echo "Packaging symlink regression passed; sentinel app and archive bytes unchanged."
