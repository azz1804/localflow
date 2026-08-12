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

has_usable_api_key() {
  [[ -f "$1" ]] || return 1
  awk -F= '
    /^OPENAI_API_KEY=/ {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", value)
      if (value ~ /^sk-[A-Za-z0-9_-]{16,}$/ && value != "sk-your-key") {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

if [[ -f "$ROOT_DIR/.env" && ! -f "$SUPPORT_ENV" ]]; then
  mkdir -p "$SUPPORT_DIR"
  cp "$ROOT_DIR/.env" "$SUPPORT_ENV"
elif [[ -f "$ROOT_DIR/.env" ]] \
    && has_usable_api_key "$ROOT_DIR/.env" \
    && ! has_usable_api_key "$SUPPORT_ENV"; then
  # Repair only the key and retain the user's modes, hotkeys, and themes.
  mkdir -p "$SUPPORT_DIR"
  API_KEY="$(awk -F= '/^OPENAI_API_KEY=/ { print substr($0, index($0, "=") + 1); exit }' "$ROOT_DIR/.env")"
  TEMP_ENV="$(mktemp "$SUPPORT_DIR/.env.installing.XXXXXX")"
  REPLACED=0
  if [[ -f "$SUPPORT_ENV" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == OPENAI_API_KEY=* ]]; then
        printf 'OPENAI_API_KEY=%s\n' "$API_KEY" >> "$TEMP_ENV"
        REPLACED=1
      else
        printf '%s\n' "$line" >> "$TEMP_ENV"
      fi
    done < "$SUPPORT_ENV"
  else
    cp "$ROOT_DIR/.env.example" "$TEMP_ENV"
  fi
  if [[ "$REPLACED" != "1" ]]; then
    printf 'OPENAI_API_KEY=%s\n' "$API_KEY" >> "$TEMP_ENV"
  fi
  chmod 600 "$TEMP_ENV"
  mv "$TEMP_ENV" "$SUPPORT_ENV"
  unset API_KEY
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
