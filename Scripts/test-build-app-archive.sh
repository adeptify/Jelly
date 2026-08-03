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
EXTRACTED_INFO_PLIST="$EXTRACTED_APP/Contents/Info.plist"
plutil -lint "$EXTRACTED_INFO_PLIST"
if ! exported_type_identifier=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$EXTRACTED_INFO_PLIST"); then
  echo "Archive Info.plist is missing UTExportedTypeDeclarations.0.UTTypeIdentifier." >&2
  exit 1
fi
if [[ "$exported_type_identifier" != "com.oreal.personalcalendar.item" ]]; then
  echo "Unexpected exported type identifier: $exported_type_identifier" >&2
  exit 1
fi
if ! exported_type_description=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeDescription' "$EXTRACTED_INFO_PLIST"); then
  echo "Archive Info.plist is missing UTExportedTypeDeclarations.0.UTTypeDescription." >&2
  exit 1
fi
if [[ "$exported_type_description" != "个人月历事项" ]]; then
  echo "Unexpected exported type description: $exported_type_description" >&2
  exit 1
fi
if ! exported_type_conforms_to=$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeConformsTo' "$EXTRACTED_INFO_PLIST"); then
  echo "Archive Info.plist is missing UTExportedTypeDeclarations.0.UTTypeConformsTo." >&2
  exit 1
fi
if ! print -r -- "$exported_type_conforms_to" | grep -Eq '^[[:space:]]*public\.json$'; then
  echo "Archive exported type does not conform to public.json." >&2
  exit 1
fi
echo "Packaging archive regression passed; extracted app has a strict valid signature."
