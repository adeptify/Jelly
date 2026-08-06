#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-package.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
SENTINEL_DIR="$TEMP_ROOT/sentinel"
SENTINEL_APP="$SENTINEL_DIR/Jelly.app"
SENTINEL_FILE="$SENTINEL_APP/Contents/sentinel.bin"
SENTINEL_ARCHIVE="$SENTINEL_DIR/Jelly.app.zip"
SENTINEL_DMG="$SENTINEL_DIR/Jelly.dmg"

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
print -n "sentinel dmg must survive symlink rejection" > "$SENTINEL_DMG"
APP_BEFORE_HASH=$(shasum -a 256 "$SENTINEL_FILE" | awk '{print $1}')
ARCHIVE_BEFORE_HASH=$(shasum -a 256 "$SENTINEL_ARCHIVE" | awk '{print $1}')
DMG_BEFORE_HASH=$(shasum -a 256 "$SENTINEL_DMG" | awk '{print $1}')

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
DMG_AFTER_HASH=$(shasum -a 256 "$SENTINEL_DMG" | awk '{print $1}')
if [[ "$APP_BEFORE_HASH" != "$APP_AFTER_HASH" || \
      "$ARCHIVE_BEFORE_HASH" != "$ARCHIVE_AFTER_HASH" || \
      "$DMG_BEFORE_HASH" != "$DMG_AFTER_HASH" ]]; then
  echo "Sentinel app, ZIP, or DMG changed despite dist symlink rejection." >&2
  exit 1
fi

# A non-regular formal ZIP target is rejected without touching its contents.
/bin/rm "$PROJECT_COPY/dist"
mkdir -p "$PROJECT_COPY/dist/Jelly.app.zip"
NONREGULAR_SENTINEL="$PROJECT_COPY/dist/Jelly.app.zip/sentinel"
print -n "nonregular formal target" > "$NONREGULAR_SENTINEL"
NONREGULAR_HASH=$(shasum -a 256 "$NONREGULAR_SENTINEL" | awk '{print $1}')
set +e
zsh "$PROJECT_COPY/Scripts/build-app.sh" >/dev/null
STATUS=$?
set -e
[[ $STATUS -eq 2 ]]
[[ "$(shasum -a 256 "$NONREGULAR_SENTINEL" | awk '{print $1}')" == "$NONREGULAR_HASH" ]]

# A symlinked formal DMG cannot redirect publication outside dist.
find "$PROJECT_COPY/dist/Jelly.app.zip" -depth -delete
print -n "legacy zip sentinel" > "$PROJECT_COPY/dist/Jelly.app.zip"
LEGACY_ZIP_HASH=$(shasum -a 256 "$PROJECT_COPY/dist/Jelly.app.zip" | awk '{print $1}')
ln -s "$SENTINEL_DMG" "$PROJECT_COPY/dist/Jelly.dmg"
set +e
zsh "$PROJECT_COPY/Scripts/build-app.sh" >/dev/null
STATUS=$?
set -e
[[ $STATUS -eq 2 ]]
[[ "$(shasum -a 256 "$PROJECT_COPY/dist/Jelly.app.zip" | awk '{print $1}')" == "$LEGACY_ZIP_HASH" ]]
[[ "$(shasum -a 256 "$SENTINEL_DMG" | awk '{print $1}')" == "$DMG_BEFORE_HASH" ]]

# A non-regular formal DMG target is rejected symmetrically and cannot alter
# its authoritative ZIP peer or any file already inside the directory target.
/bin/rm "$PROJECT_COPY/dist/Jelly.dmg"
mkdir -p "$PROJECT_COPY/dist/Jelly.dmg"
NONREGULAR_DMG_SENTINEL="$PROJECT_COPY/dist/Jelly.dmg/sentinel"
print -n "nonregular dmg target" > "$NONREGULAR_DMG_SENTINEL"
NONREGULAR_DMG_HASH=$(shasum -a 256 "$NONREGULAR_DMG_SENTINEL" | awk '{print $1}')
set +e
zsh "$PROJECT_COPY/Scripts/build-app.sh" >/dev/null
STATUS=$?
set -e
[[ $STATUS -eq 2 ]]
[[ "$(shasum -a 256 "$PROJECT_COPY/dist/Jelly.app.zip" | awk '{print $1}')" == "$LEGACY_ZIP_HASH" ]]
[[ "$(shasum -a 256 "$NONREGULAR_DMG_SENTINEL" | awk '{print $1}')" == "$NONREGULAR_DMG_HASH" ]]

echo "Packaging symlink/non-regular regressions passed; all sentinels stayed unchanged."
