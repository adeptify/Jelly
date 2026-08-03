#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR="$PROJECT_DIR/dist"
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/personal-calendar-build.XXXXXX")
STAGING_APP="$STAGING_ROOT/个人月历.app"
STAGING_ZIP="$STAGING_ROOT/个人月历.app.zip"
STAGING_DMG="$STAGING_ROOT/个人月历.dmg"
DMG_SOURCE="$STAGING_ROOT/dmg-source"
ZIP_VERIFY_ROOT="$STAGING_ROOT/zip-verify"
DMG_VERIFY_ROOT="$STAGING_ROOT/dmg-verify"

FORMAL_ZIP=""
FORMAL_DMG=""
CANDIDATE_ZIP=""
CANDIDATE_DMG=""
BACKUP_ZIP=""
BACKUP_DMG=""
ACTIVE_MOUNT_POINT=""
ACTIVE_DEVICE_ENTRY=""
LAST_VERIFIED_ZIP_CDHASH=""
LAST_VERIFIED_DMG_CDHASH=""
PUBLICATION_PENDING=false
PRIOR_ZIP_EXISTS=false
PRIOR_DMG_EXISTS=false

remove_explicit_file() {
  local target_path="$1"
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    rm -f "$target_path"
  fi
}

remove_formal_pair() {
  local result=0
  remove_explicit_file "$FORMAL_ZIP" || result=1
  remove_explicit_file "$FORMAL_DMG" || result=1
  return "$result"
}

verify_app() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -d "$app" && ! -L "$app" ]] || return 1
  [[ -f "$plist" && ! -L "$plist" ]] || return 1
  plutil -lint "$plist" >/dev/null || return 1
  local executable
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist") || return 1
  [[ -n "$executable" ]] || return 1
  local executable_path="$app/Contents/MacOS/$executable"
  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] || return 1
  codesign --verify --deep --strict "$app" || return 1
}

app_cdhash() {
  local app="$1"
  local cdhash
  cdhash=$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}') || return 1
  [[ -n "$cdhash" ]] || return 1
  print -r -- "$cdhash"
}

verify_zip() {
  local archive="$1"
  local verify_root="$2"
  [[ -f "$archive" && ! -L "$archive" ]] || return 1
  if [[ -e "$verify_root" || -L "$verify_root" ]]; then
    find "$verify_root" -depth -delete || return 1
  fi
  mkdir -p "$verify_root" || return 1
  ditto -x -k "$archive" "$verify_root" || return 1
  local app="$verify_root/个人月历.app"
  if xattr -lr "$app" | grep -E 'com\.apple\.(FinderInfo|fileprovider)' >/dev/null; then
    echo "ZIP extraction contained FileProvider signing detritus." >&2
    return 1
  fi
  verify_app "$app" || return 1
  LAST_VERIFIED_ZIP_CDHASH=$(app_cdhash "$app") || return 1
}

mounted_value() {
  local plist="$1"
  local key="$2"
  local index value
  for index in {0..20}; do
    if value=$(plutil -extract "system-entities.$index.$key" raw -o - "$plist" 2>/dev/null); then
      [[ -n "$value" ]] && {
        print -r -- "$value"
        return 0
      }
    fi
  done
  return 1
}

detach_active_image() {
  local detach_target="$ACTIVE_DEVICE_ENTRY"
  [[ -n "$detach_target" ]] || detach_target="$ACTIVE_MOUNT_POINT"
  [[ -n "$detach_target" ]] || return 0
  if hdiutil detach "$detach_target" >/dev/null; then
    ACTIVE_DEVICE_ENTRY=""
    ACTIVE_MOUNT_POINT=""
    return 0
  fi
  echo "Could not detach active DMG device=$ACTIVE_DEVICE_ENTRY mount=$ACTIVE_MOUNT_POINT" >&2
  return 1
}

verify_dmg() {
  local dmg="$1"
  local verify_root="$2"
  local attach_plist="$verify_root/attach.plist"
  [[ -f "$dmg" && ! -L "$dmg" ]] || return 1
  if [[ -e "$verify_root" || -L "$verify_root" ]]; then
    find "$verify_root" -depth -delete || return 1
  fi
  mkdir -p "$verify_root" || return 1
  hdiutil attach -readonly -nobrowse -plist "$dmg" > "$attach_plist" || return 1
  ACTIVE_DEVICE_ENTRY=$(mounted_value "$attach_plist" dev-entry) || ACTIVE_DEVICE_ENTRY=""
  ACTIVE_MOUNT_POINT=$(mounted_value "$attach_plist" mount-point) || {
    echo "DMG attach did not report a mount point: $dmg (device=$ACTIVE_DEVICE_ENTRY)" >&2
    return 1
  }

  local result=0
  local mounted_app="$ACTIVE_MOUNT_POINT/个人月历.app"
  verify_app "$mounted_app" || result=1
  if [[ "$result" == 0 ]]; then
    LAST_VERIFIED_DMG_CDHASH=$(app_cdhash "$mounted_app") || result=1
  fi
  if [[ ! -L "$ACTIVE_MOUNT_POINT/Applications" ]] || \
     [[ "$(readlink "$ACTIVE_MOUNT_POINT/Applications")" != "/Applications" ]]; then
    echo "DMG is missing the Finder Applications shortcut." >&2
    result=1
  fi
  detach_active_image || result=1
  return "$result"
}

verify_pair() {
  local zip="$1"
  local dmg="$2"
  local suffix="$3"
  LAST_VERIFIED_ZIP_CDHASH=""
  LAST_VERIFIED_DMG_CDHASH=""
  verify_zip "$zip" "$ZIP_VERIFY_ROOT-$suffix" || return 1
  verify_dmg "$dmg" "$DMG_VERIFY_ROOT-$suffix" || return 1
  if [[ "$LAST_VERIFIED_ZIP_CDHASH" != "$LAST_VERIFIED_DMG_CDHASH" ]]; then
    echo "ZIP/DMG app CDHash mismatch: ZIP=$LAST_VERIFIED_ZIP_CDHASH DMG=$LAST_VERIFIED_DMG_CDHASH" >&2
    return 1
  fi
}

clear_transaction() {
  PUBLICATION_PENDING=false
}

rollback_publication() {
  [[ "$PUBLICATION_PENDING" == true ]] || return 0
  trap '' HUP INT TERM

  local result=0
  remove_formal_pair || result=1
  if [[ "$PRIOR_ZIP_EXISTS" == true || "$PRIOR_DMG_EXISTS" == true ]]; then
    if [[ "$PRIOR_ZIP_EXISTS" == true && -f "$BACKUP_ZIP" ]]; then
      cp -p "$BACKUP_ZIP" "$FORMAL_ZIP" || result=1
    fi
    if [[ "$PRIOR_DMG_EXISTS" == true && -f "$BACKUP_DMG" ]]; then
      cp -p "$BACKUP_DMG" "$FORMAL_DMG" || result=1
    fi
    if [[ "$result" == 0 && "$PRIOR_ZIP_EXISTS" == true && "$PRIOR_DMG_EXISTS" == true ]] && \
       ! verify_pair "$FORMAL_ZIP" "$FORMAL_DMG" rollback; then
      result=1
    elif [[ "$result" == 0 && "$PRIOR_ZIP_EXISTS" == true && "$PRIOR_DMG_EXISTS" == false ]] && \
         ! verify_zip "$FORMAL_ZIP" "$ZIP_VERIFY_ROOT-rollback"; then
      result=1
    fi
  fi

  if [[ "$result" != 0 ]]; then
    remove_formal_pair || true
    echo "Could not restore the prior authoritative ZIP/DMG pair; backups remain at:" >&2
    echo "$BACKUP_ZIP" >&2
    echo "$BACKUP_DMG" >&2
    return 1
  fi
  clear_transaction
}

cleanup() {
  trap '' HUP INT TERM
  if [[ -n "$ACTIVE_DEVICE_ENTRY" || -n "$ACTIVE_MOUNT_POINT" ]]; then
    detach_active_image >/dev/null 2>&1 || true
  fi
  if [[ "$PUBLICATION_PENDING" == true ]]; then
    rollback_publication || true
  fi
  for package_path in "$CANDIDATE_ZIP" "$CANDIDATE_DMG"; do
    [[ -n "$package_path" ]] && remove_explicit_file "$package_path" || true
  done
  if [[ "$PUBLICATION_PENDING" != true ]]; then
    for package_path in "$BACKUP_ZIP" "$BACKUP_DMG"; do
      [[ -n "$package_path" ]] && remove_explicit_file "$package_path" || true
    done
  fi
  find "$STAGING_ROOT" -depth -delete || true
}

handle_signal() {
  local signal_name="$1"
  local exit_code="$2"
  trap '' HUP INT TERM
  echo "Received $signal_name during package publication; restoring the authoritative pair." >&2
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
FORMAL_ZIP="$DIST_REAL/个人月历.app.zip"
FORMAL_DMG="$DIST_REAL/个人月历.dmg"
CANDIDATE_ZIP="$DIST_REAL/.个人月历.app.zip.candidate.$$"
CANDIDATE_DMG="$DIST_REAL/.个人月历.dmg.candidate.$$"
BACKUP_ZIP="$DIST_REAL/.个人月历.app.zip.backup.$$"
BACKUP_DMG="$DIST_REAL/.个人月历.dmg.backup.$$"

for formal in "$FORMAL_ZIP" "$FORMAL_DMG"; do
  if [[ -L "$formal" || ( -e "$formal" && ! -f "$formal" ) ]]; then
    echo "Unexpected package output target: $formal" >&2
    exit 2
  fi
done
if [[ -f "$FORMAL_ZIP" && -f "$FORMAL_DMG" ]]; then
  PRIOR_ZIP_EXISTS=true
  PRIOR_DMG_EXISTS=true
elif [[ -f "$FORMAL_ZIP" && ! -e "$FORMAL_DMG" ]]; then
  # V1 shipped ZIP-only. Preserve that exact legacy state if the first V2 pair
  # publication fails, then publish both formats together on success.
  PRIOR_ZIP_EXISTS=true
elif [[ -e "$FORMAL_DMG" ]]; then
  echo "Refusing a DMG without its authoritative ZIP peer in dist." >&2
  exit 2
fi
for temporary in "$CANDIDATE_ZIP" "$CANDIDATE_DMG" "$BACKUP_ZIP" "$BACKUP_DMG"; do
  if [[ -e "$temporary" || -L "$temporary" ]]; then
    echo "Unexpected temporary package target: $temporary" >&2
    exit 2
  fi
done

CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/PersonalCalendar" "$MACOS_DIR/PersonalCalendar"
cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/PersonalCalendar"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
xattr -cr "$STAGING_APP"
codesign --force --deep --sign - "$STAGING_APP"
xattr -cr "$STAGING_APP"
verify_app "$STAGING_APP"

ditto --norsrc -c -k --keepParent "$STAGING_APP" "$STAGING_ZIP"
mkdir -p "$DMG_SOURCE"
ditto --norsrc "$STAGING_APP" "$DMG_SOURCE/个人月历.app"
ln -s /Applications "$DMG_SOURCE/Applications"
hdiutil create -volname "个人月历" -srcfolder "$DMG_SOURCE" -ov -format UDZO "$STAGING_DMG" >/dev/null

verify_pair "$STAGING_ZIP" "$STAGING_DMG" staging || {
  echo "Staged ZIP/DMG verification failed; neither package was published." >&2
  exit 1
}
mv "$STAGING_ZIP" "$CANDIDATE_ZIP"
mv "$STAGING_DMG" "$CANDIDATE_DMG"
verify_pair "$CANDIDATE_ZIP" "$CANDIDATE_DMG" candidate || {
  echo "Candidate ZIP/DMG verification failed; neither package was published." >&2
  exit 1
}

if [[ "$PRIOR_ZIP_EXISTS" == true ]]; then
  cp -p "$FORMAL_ZIP" "$BACKUP_ZIP"
fi
if [[ "$PRIOR_DMG_EXISTS" == true ]]; then
  cp -p "$FORMAL_DMG" "$BACKUP_DMG"
fi
PUBLICATION_PENDING=true
mv -f "$CANDIDATE_ZIP" "$FORMAL_ZIP"
CANDIDATE_ZIP=""
mv -f "$CANDIDATE_DMG" "$FORMAL_DMG"
CANDIDATE_DMG=""

if ! verify_pair "$FORMAL_ZIP" "$FORMAL_DMG" published; then
  echo "Published pair verification failed; restoring the prior authoritative pair." >&2
  rollback_publication || true
  exit 1
fi
clear_transaction
remove_explicit_file "$BACKUP_ZIP"
remove_explicit_file "$BACKUP_DMG"
BACKUP_ZIP=""
BACKUP_DMG=""

# A Documents-backed raw app is only a best-effort launcher. The ZIP and DMG
# above are the authoritative pair and have already passed independent checks.
if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
  rm -rf "$APP_DIR" || true
fi
if [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]] && \
   ditto --norsrc "$STAGING_APP" "$APP_DIR" && \
   xattr -cr "$APP_DIR" && \
   verify_app "$APP_DIR"; then
  echo "$APP_DIR"
elif [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
  rm -rf "$APP_DIR" || true
fi

echo "$FORMAL_ZIP"
echo "$FORMAL_DMG"
