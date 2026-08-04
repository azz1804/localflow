#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="${1:?Usage: Scripts/notarize_release.sh LocalFlow-version.zip}"
KEYCHAIN_PROFILE="${LOCALFLOW_NOTARY_PROFILE:?Set LOCALFLOW_NOTARY_PROFILE to a notarytool keychain profile.}"

xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localflow-notary.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ditto -x -k "$ARCHIVE_PATH" "$TEMP_DIR"
xcrun stapler staple "$TEMP_DIR/LocalFlow.app"
xcrun stapler validate "$TEMP_DIR/LocalFlow.app"
ditto -c -k --keepParent "$TEMP_DIR/LocalFlow.app" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"
