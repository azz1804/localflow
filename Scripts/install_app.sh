#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
APP_NAME="LocalFlow.app"
DEST_APP="$DEST_DIR/$APP_NAME"
STAGED_APP="$DEST_DIR/.${APP_NAME}.installing.$$"
BACKUP_APP="$DEST_DIR/.${APP_NAME}.backup.$$"

cd "$ROOT_DIR"

APP_PATH="$("$ROOT_DIR/Scripts/build_app.sh")"

if [[ "${LOCALFLOW_SKIP_TERMINATE:-0}" != "1" ]]; then
  osascript -e 'tell application "LocalFlow" to quit' >/dev/null 2>&1 || true
  for _ in {1..60}; do
    if ! pgrep -x LocalFlow >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done

  if pgrep -x LocalFlow >/dev/null 2>&1; then
    echo "LocalFlow is still busy; installation aborted without forcing it to quit." >&2
    exit 1
  fi
fi

SUPPORT_DIR="$HOME/Library/Application Support/LocalFlow"
SUPPORT_ENV="$SUPPORT_DIR/.env"

if [[ -f "$ROOT_DIR/.env" && ! -f "$SUPPORT_ENV" ]]; then
  mkdir -p "$SUPPORT_DIR"
  cp "$ROOT_DIR/.env" "$SUPPORT_ENV"
fi

if [[ -f "$SUPPORT_ENV" ]]; then
  chmod 600 "$SUPPORT_ENV"
fi

if [[ "$DEST_DIR" != "/Applications" ]]; then
  mkdir -p "$DEST_DIR"
fi

run_at_destination() {
  if [[ "$DEST_DIR" != "/Applications" || -w "$DEST_DIR" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup_staging() {
  run_at_destination rm -rf "$STAGED_APP" >/dev/null 2>&1 || true
}
trap cleanup_staging EXIT

run_at_destination rm -rf "$STAGED_APP" "$BACKUP_APP"
run_at_destination ditto "$APP_PATH" "$STAGED_APP"

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$STAGED_APP"
fi

if [[ -e "$DEST_APP" ]]; then
  run_at_destination mv "$DEST_APP" "$BACKUP_APP"
fi

if ! run_at_destination mv "$STAGED_APP" "$DEST_APP"; then
  if [[ -e "$BACKUP_APP" ]]; then
    run_at_destination mv "$BACKUP_APP" "$DEST_APP" || true
  fi
  echo "Installation failed; the previous LocalFlow app was restored." >&2
  exit 1
fi

if [[ -e "$BACKUP_APP" ]]; then
  run_at_destination rm -rf "$BACKUP_APP"
fi

if [[ "$DEST_DIR" == "/Applications" && -e "$HOME/Applications/$APP_NAME" ]]; then
  rm -rf "$HOME/Applications/$APP_NAME"
fi

trap - EXIT

if [[ "${LOCALFLOW_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "$DEST_APP" --args --show-dashboard
fi
echo "$DEST_APP"
