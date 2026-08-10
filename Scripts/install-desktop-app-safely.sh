#!/bin/sh
set -euo pipefail
# Safe Desktop install for reviewed Jelly.app. Never launches against default
# user data during verification.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/dist/Jelly.app}"
DEST="${HOME}/Desktop/Jelly.app"
BACKUP_ROOT="${HOME}/Desktop/Jelly-app-backups"
if [[ ! -d "$SRC" ]]; then
  echo "Source app not found: $SRC" >&2
  exit 1
fi
mkdir -p "$BACKUP_ROOT"
if [[ -d "$DEST" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/Jelly-$stamp.app"
  echo "Backing up existing Desktop app to $backup"
  mv "$DEST" "$backup"
fi
stage="$HOME/Desktop/Jelly-install-staging-$$.app"
rm -rf "$stage"
cp -R "$SRC" "$stage"
codesign --verify --deep --strict "$stage"
mv "$stage" "$DEST"
echo "Installed $DEST"
echo "Verify only with JELLY_ACCEPTANCE_DATA_DIRECTORY set to a temp path."
