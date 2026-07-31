#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LocalFlow"
CONFIGURATION="${1:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
BUNDLE_OUTPUT_DIR="${LOCALFLOW_BUNDLE_OUTPUT_DIR:-${TMPDIR:-/tmp}/LocalFlow-build/$CONFIGURATION}"
APP_DIR="$BUNDLE_OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="${LOCALFLOW_VERSION:-0.3.0}"
BUILD_NUMBER="${LOCALFLOW_BUILD_NUMBER:-3}"
GIT_COMMIT="${LOCALFLOW_GIT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')}"

if ! git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- 2>/dev/null; then
  GIT_COMMIT="${GIT_COMMIT}-dirty"
fi

cd "$ROOT_DIR"

if [[ "$CONFIGURATION" == "debug" ]]; then
  swift build >&2
else
  swift build -c release >&2
fi

mkdir -p "$BUNDLE_OUTPUT_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>LocalFlow</string>
  <key>CFBundleIdentifier</key>
  <string>local.localflow.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>LocalFlow</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LocalFlowGitCommit</key>
  <string>unknown</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>LocalFlow records your voice while you hold the dictation hotkey, then transcribes it.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>LocalFlow listens for your configured global dictation hotkeys while it runs in the background.</string>
</dict>
</plist>
PLIST

plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
plutil -replace LocalFlowGitCommit -string "$GIT_COMMIT" "$CONTENTS_DIR/Info.plist"

if [[ -f "$ROOT_DIR/Config/dictionary.json" ]]; then
  cp "$ROOT_DIR/Config/dictionary.json" "$RESOURCES_DIR/dictionary.json"
else
  cp "$ROOT_DIR/Config/dictionary.example.json" "$RESOURCES_DIR/dictionary.json"
fi

if [[ -f "$ROOT_DIR/Assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [[ -f "$ROOT_DIR/Assets/BrandOrb.png" ]]; then
  cp "$ROOT_DIR/Assets/BrandOrb.png" "$RESOURCES_DIR/BrandOrb.png"
fi

if [[ -f "$ROOT_DIR/Assets/MenuBarOrb.png" ]]; then
  cp "$ROOT_DIR/Assets/MenuBarOrb.png" "$RESOURCES_DIR/MenuBarOrb.png"
fi

if command -v codesign >/dev/null 2>&1; then
  # Finder and File Provider metadata invalidates an otherwise valid bundle
  # signature when the repository lives in a synchronized folder.
  xattr -cr "$APP_DIR"

  CODESIGN_IDENTITY="${LOCALFLOW_CODESIGN_IDENTITY:--}"
  CODESIGN_KEYCHAIN="${LOCALFLOW_CODESIGN_KEYCHAIN:-}"
  CODESIGN_REQUIREMENTS="${LOCALFLOW_CODESIGN_REQUIREMENTS:-}"

  if [[ "${LOCALFLOW_REQUIRE_DISTRIBUTION_SIGNING:-0}" == "1" && "$CODESIGN_IDENTITY" == "-" ]]; then
    printf 'A Developer ID identity is required for a distribution build.\n' >&2
    exit 1
  fi

  if [[ "$CODESIGN_IDENTITY" == "-" && -z "$CODESIGN_REQUIREMENTS" ]]; then
    # Keep local TCC permissions stable across ad-hoc development rebuilds.
    CODESIGN_REQUIREMENTS='=designated => identifier "local.localflow.app"'
  fi

  codesign_args=(--force --deep --sign "$CODESIGN_IDENTITY")
  if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
  fi
  if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  if [[ -n "$CODESIGN_REQUIREMENTS" ]]; then
    codesign_args+=(--requirements "$CODESIGN_REQUIREMENTS")
  fi

  if ! codesign "${codesign_args[@]}" "$APP_DIR" >/dev/null 2>&1; then
    codesign --force --deep --sign - --requirements '=designated => identifier "local.localflow.app"' "$APP_DIR"
  fi

  codesign --verify --deep --strict "$APP_DIR"
fi

echo "$APP_DIR"
