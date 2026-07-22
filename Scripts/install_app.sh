#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
APP_NAME="LocalFlow.app"
DEST_APP="$DEST_DIR/$APP_NAME"

cd "$ROOT_DIR"

APP_PATH="$("$ROOT_DIR/Scripts/build_app.sh")"

if [[ "${LOCALFLOW_SKIP_TERMINATE:-0}" != "1" ]]; then
  osascript -e 'tell application "LocalFlow" to quit' >/dev/null 2>&1 || true
  sleep 1

  if pgrep -x LocalFlow >/dev/null 2>&1; then
    pkill -x LocalFlow >/dev/null 2>&1 || true
    sleep 1
  fi
fi

SUPPORT_DIR="$HOME/Library/Application Support/LocalFlow"
SUPPORT_ENV="$SUPPORT_DIR/.env"

if [[ -f "$ROOT_DIR/.env" && ! -f "$SUPPORT_ENV" ]]; then
  mkdir -p "$SUPPORT_DIR"
  cp "$ROOT_DIR/.env" "$SUPPORT_ENV"
fi

if [[ "$DEST_DIR" == "/Applications" ]]; then
  if [[ -w "$DEST_DIR" ]]; then
    rm -rf "$DEST_APP"
    ditto "$APP_PATH" "$DEST_APP"
  else
    sudo rm -rf "$DEST_APP"
    sudo ditto "$APP_PATH" "$DEST_APP"
  fi
  rm -rf "$HOME/Applications/$APP_NAME"
else
  mkdir -p "$DEST_DIR"
  rm -rf "$DEST_APP"
  ditto "$APP_PATH" "$DEST_APP"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$DEST_APP"
fi

if [[ "${LOCALFLOW_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "$DEST_APP"
fi
echo "$DEST_APP"
