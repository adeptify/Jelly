#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-archive.XXXXXX")
PROJECT_COPY="$TEMP_ROOT/calendar-v1"
ZIP_VERIFY_ROOT="$TEMP_ROOT/zip-verify"
DMG_VERIFY_ROOT="$TEMP_ROOT/dmg-verify"
ACTIVE_MOUNT_POINT=""

cleanup() {
  if [[ -n "$ACTIVE_MOUNT_POINT" ]]; then
    hdiutil detach "$ACTIVE_MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  find "$TEMP_ROOT" -depth -delete
}
trap cleanup EXIT

rsync -a --exclude '.build' --exclude 'dist' --exclude '.git' "$PROJECT_DIR/" "$PROJECT_COPY/"
zsh "$PROJECT_COPY/Scripts/build-app.sh"

ARCHIVE="$PROJECT_COPY/dist/个人月历.app.zip"
DMG="$PROJECT_COPY/dist/个人月历.dmg"
[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || {
  echo "Expected authoritative ZIP: $ARCHIVE" >&2
  exit 1
}
[[ -f "$DMG" && ! -L "$DMG" ]] || {
  echo "Expected authoritative DMG: $DMG" >&2
  exit 1
}

verify_app() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -d "$app" && ! -L "$app" && -f "$plist" && ! -L "$plist" ]]
  plutil -lint "$plist" >/dev/null
  local executable
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
  [[ -f "$app/Contents/MacOS/$executable" && -x "$app/Contents/MacOS/$executable" ]]
  codesign --verify --deep --strict "$app"
  local exported_identifier exported_description exported_conformance
  exported_identifier=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$plist")
  exported_description=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeDescription' "$plist")
  exported_conformance=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeConformsTo' "$plist")
  [[ "$exported_identifier" == "com.oreal.personalcalendar.item" ]]
  [[ "$exported_description" == "个人月历事项" ]]
  print -r -- "$exported_conformance" | grep -Eq '^[[:space:]]*public\.json$'
}

mkdir -p "$ZIP_VERIFY_ROOT"
ditto -x -k "$ARCHIVE" "$ZIP_VERIFY_ROOT"
ZIP_APP="$ZIP_VERIFY_ROOT/个人月历.app"
if xattr -lr "$ZIP_APP" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
  echo "ZIP extraction contained FileProvider signing detritus." >&2
  exit 1
fi
verify_app "$ZIP_APP"
ZIP_CDHASH=$(codesign -dv --verbose=4 "$ZIP_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')
[[ -n "$ZIP_CDHASH" ]]

mkdir -p "$DMG_VERIFY_ROOT"
ATTACH_PLIST="$DMG_VERIFY_ROOT/attach.plist"
hdiutil attach -readonly -nobrowse -plist "$DMG" > "$ATTACH_PLIST"
for index in {0..20}; do
  if ACTIVE_MOUNT_POINT=$(plutil -extract "system-entities.$index.mount-point" raw -o - "$ATTACH_PLIST" 2>/dev/null); then
    [[ -n "$ACTIVE_MOUNT_POINT" ]] && break
  fi
  ACTIVE_MOUNT_POINT=""
done
[[ -n "$ACTIVE_MOUNT_POINT" ]] || {
  echo "DMG attach did not report a mount point." >&2
  exit 1
}
DMG_APP="$ACTIVE_MOUNT_POINT/个人月历.app"
verify_app "$DMG_APP"
[[ -L "$ACTIVE_MOUNT_POINT/Applications" ]]
[[ "$(readlink "$ACTIVE_MOUNT_POINT/Applications")" == "/Applications" ]]
DMG_CDHASH=$(codesign -dv --verbose=4 "$DMG_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')
[[ "$DMG_CDHASH" == "$ZIP_CDHASH" ]]
hdiutil detach "$ACTIVE_MOUNT_POINT" >/dev/null
ACTIVE_MOUNT_POINT=""

print "Packaging pair regression passed; fresh ZIP and readonly DMG contain the same strictly signed app (CDHash=$ZIP_CDHASH)."
