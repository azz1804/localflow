#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
APP_NAME="LocalFlow.app"
DEST_APP="$DEST_DIR/$APP_NAME"

cd "$ROOT_DIR"

osascript -e 'tell application "LocalFlow" to quit' >/dev/null 2>&1 || true
sleep 1

if pgrep -x LocalFlow >/dev/null 2>&1; then
  pkill -x LocalFlow >/dev/null 2>&1 || true
  sleep 1
fi

APP_PATH="$("$ROOT_DIR/Scripts/build_app.sh")"

if [[ "$DEST_DIR" == "/Applications" ]]; then
  sudo rm -rf "$DEST_APP"
  sudo ditto "$APP_PATH" "$DEST_APP"
else
  mkdir -p "$DEST_DIR"
  rm -rf "$DEST_APP"
  ditto "$APP_PATH" "$DEST_APP"
fi

open "$DEST_APP"
echo "$DEST_APP"
