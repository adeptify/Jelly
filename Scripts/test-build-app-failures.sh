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
APP_DIR="$DIST_DIR/个人月历.app"
ARCHIVE_PATH="$DIST_DIR/个人月历.app.zip"
DMG_PATH="$DIST_DIR/个人月历.dmg"
COMMON_ENV=(PATH="$FAKE_BIN:$PATH" BUILD_APP_FAKE_SWIFT_BIN_DIR="$SOURCE_BIN_DIR")

assert_no_publish_residue() {
  local residue
  residue=$(find "$DIST_DIR" -maxdepth 1 \( -name '.个人月历.app.zip.*' -o -name '.个人月历.dmg.*' \) -print)
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

env "${COMMON_ENV[@]}" zsh "$BUILD_SCRIPT" >/dev/null
assert_pair_present
baseline_hashes=$(pair_hashes)

# A DMG creation failure occurs before either candidate reaches dist.
if env "${COMMON_ENV[@]}" BUILD_APP_FAULT_HDIUTIL_CREATE=true zsh "$BUILD_SCRIPT" >/dev/null 2>&1; then
  print -u2 "Expected staged DMG creation failure."
  exit 1
fi
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
mismatch_dmg="$mismatch_root/个人月历-mismatched.dmg"
mkdir -p "$mismatch_extract" "$mismatch_source"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$mismatch_extract"
mismatch_app="$mismatch_extract/个人月历.app"
/usr/bin/plutil -replace CFBundleVersion -string 2 "$mismatch_app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$mismatch_app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$mismatch_app"
/usr/bin/ditto --norsrc "$mismatch_app" "$mismatch_source/个人月历.app"
ln -s /Applications "$mismatch_source/Applications"
/usr/bin/hdiutil create -volname "个人月历" -srcfolder "$mismatch_source" -ov -format UDZO "$mismatch_dmg" >/dev/null

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
