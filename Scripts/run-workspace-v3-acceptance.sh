#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
acceptance_root="$(mktemp -d "${TMPDIR:-/tmp}/jelly-v3-acceptance.XXXXXX")"
mkdir -p "$acceptance_root/data"
APP="$ROOT/dist/Jelly.app"
if [[ ! -d "$APP" ]]; then
  echo "Missing $APP — run ./Scripts/build-app.sh first" >&2
  exit 1
fi
echo "acceptance_root=$acceptance_root"
echo "data=$acceptance_root/data"
echo "app=$APP"
echo "Launching isolated app (does not touch default Application Support)…"
open -n --env "JELLY_ACCEPTANCE_DATA_DIRECTORY=$acceptance_root/data" "$APP"
echo "Record GUI checklist results in docs/validation/workspace-v3/visual-checklist.md"
