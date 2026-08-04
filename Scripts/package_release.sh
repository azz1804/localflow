#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${LOCALFLOW_VERSION:-0.3.0}}"
OUTPUT_DIR="${LOCALFLOW_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"

mkdir -p "$OUTPUT_DIR"

APP_PATH="$(
  LOCALFLOW_VERSION="$VERSION" \
  LOCALFLOW_REQUIRE_DISTRIBUTION_SIGNING=1 \
    "$ROOT_DIR/Scripts/build_app.sh" release
)"
ARCHIVE_PATH="$OUTPUT_DIR/LocalFlow-$VERSION.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

printf '%s\n' "$ARCHIVE_PATH"
printf '%s\n' "$CHECKSUM_PATH"
