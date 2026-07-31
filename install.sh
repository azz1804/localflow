#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${LOCALFLOW_REPOSITORY:-azz1804/localflow}"
REF="${LOCALFLOW_REF:-main}"
DEST_DIR="${LOCALFLOW_DEST_DIR:-/Applications}"
SOURCE_DIR="${LOCALFLOW_SOURCE_DIR:-}"
SKIP_API_KEY="${LOCALFLOW_SKIP_API_KEY:-0}"
EXPECTED_SHA256="${LOCALFLOW_SHA256:-}"
TEMP_DIR=""

info() {
  printf '\n\033[1;35mLocalFlow\033[0m  %s\n' "$1"
}

fail() {
  printf '\nLocalFlow installation failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS 13 or later is required."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  fail "Xcode Command Line Tools are required. Finish their installation, then run this command again."
fi

if [[ -z "$SOURCE_DIR" ]]; then
  command -v curl >/dev/null 2>&1 || fail "curl is required."
  command -v git >/dev/null 2>&1 || fail "git is required."
  command -v tar >/dev/null 2>&1 || fail "tar is required."

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localflow-install.XXXXXX")"
  SOURCE_DIR="$TEMP_DIR/source"
  ARCHIVE_PATH="$TEMP_DIR/localflow.tar.gz"
  RESOLVED_REF="$REF"
  if [[ ! "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
    RESOLVED_REF="$(git ls-remote \
      "https://github.com/$REPOSITORY.git" \
      "refs/heads/$REF" | awk 'NR == 1 { print $1 }')"
    [[ "$RESOLVED_REF" =~ ^[0-9a-fA-F]{40}$ ]] \
      || fail "Could not resolve $REPOSITORY ref $REF to an immutable commit."
  fi
  ARCHIVE_URL="https://github.com/$REPOSITORY/archive/$RESOLVED_REF.tar.gz"

  mkdir -p "$SOURCE_DIR"
  info "Downloading $REPOSITORY ($REF @ ${RESOLVED_REF:0:12})…"
  curl --fail --location --silent --show-error \
    --retry 3 --proto '=https' --tlsv1.2 \
    "$ARCHIVE_URL" --output "$ARCHIVE_PATH"

  if [[ -n "$EXPECTED_SHA256" ]]; then
    ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
    [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] \
      || fail "Archive checksum mismatch."
  fi
  tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_DIR" --strip-components=1
else
  SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
  info "Using local source at $SOURCE_DIR"
fi

[[ -x "$SOURCE_DIR/Scripts/install_app.sh" ]] || fail "The downloaded source is incomplete."

SUPPORT_DIR="$HOME/Library/Application Support/LocalFlow"
SUPPORT_ENV="$SUPPORT_DIR/.env"

if [[ -f "$SUPPORT_ENV" ]]; then
  info "Keeping the existing LocalFlow configuration."
elif [[ "$SKIP_API_KEY" != "1" && -t 0 ]]; then
  printf '\nOpenAI API key (input hidden, press Return to configure it later): ' > /dev/tty
  API_KEY=""
  IFS= read -r -s API_KEY < /dev/tty || true
  printf '\n' > /dev/tty

  if [[ -n "$API_KEY" ]]; then
    umask 077
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == OPENAI_API_KEY=* ]]; then
        printf 'OPENAI_API_KEY=%s\n' "$API_KEY"
      else
        printf '%s\n' "$line"
      fi
    done < "$SOURCE_DIR/.env.example" > "$SOURCE_DIR/.env"
    unset API_KEY
  fi
fi

info "Building and installing LocalFlow…"
LOCALFLOW_SKIP_LAUNCH="${LOCALFLOW_SKIP_LAUNCH:-0}" \
  "$SOURCE_DIR/Scripts/install_app.sh" "$DEST_DIR" >/dev/null

info "Installed in $DEST_DIR/LocalFlow.app"

if [[ ! -f "$SUPPORT_ENV" ]]; then
  printf 'Add your OpenAI key in LocalFlow > Settings before your first dictation.\n'
fi

printf 'On first use, macOS will request Microphone, Accessibility, and Input Monitoring permissions.\n'
