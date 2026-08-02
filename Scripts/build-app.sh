#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR="$PROJECT_DIR/dist"
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-build.XXXXXX")
STAGING_APP="$STAGING_ROOT/个人月历.app"
STAGING_ARCHIVE="$STAGING_ROOT/个人月历.app.zip"
VERIFY_ROOT="$STAGING_ROOT/archive-verify"

cleanup() {
  find "$STAGING_ROOT" -depth -delete
}
trap cleanup EXIT

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
mkdir -p "$VERIFY_ROOT"
ditto -x -k "$STAGING_ARCHIVE" "$VERIFY_ROOT"
EXTRACTED_APP="$VERIFY_ROOT/个人月历.app"
if xattr -lr "$EXTRACTED_APP" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
  echo "Archive extraction contained FileProvider signing detritus." >&2
  exit 1
fi
codesign --verify --deep --strict "$EXTRACTED_APP"

rm -rf "$APP_DIR"
ditto --norsrc "$STAGING_APP" "$APP_DIR"
xattr -cr "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
mv -f "$STAGING_ARCHIVE" "$ARCHIVE_PATH"

find "$VERIFY_ROOT" -depth -delete
mkdir -p "$VERIFY_ROOT"
ditto -x -k "$ARCHIVE_PATH" "$VERIFY_ROOT"
EXTRACTED_ARCHIVE_APP="$VERIFY_ROOT/个人月历.app"
if xattr -lr "$EXTRACTED_ARCHIVE_APP" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
  echo "Distributed archive extraction contained FileProvider signing detritus." >&2
  exit 1
fi
codesign --verify --deep --strict "$EXTRACTED_ARCHIVE_APP"

echo "$APP_DIR"
echo "$ARCHIVE_PATH"
