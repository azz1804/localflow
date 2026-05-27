#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LocalFlow"
CONFIGURATION="${1:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

if [[ "$CONFIGURATION" == "debug" ]]; then
  swift build >&2
else
  swift build -c release >&2
fi

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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>LocalFlow records your voice while you hold the dictation hotkey, then transcribes it.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>LocalFlow listens for your configured global dictation hotkeys while it runs in the background.</string>
</dict>
</plist>
PLIST

if [[ -f "$ROOT_DIR/Config/dictionary.json" ]]; then
  cp "$ROOT_DIR/Config/dictionary.json" "$RESOURCES_DIR/dictionary.json"
else
  cp "$ROOT_DIR/Config/dictionary.example.json" "$RESOURCES_DIR/dictionary.json"
fi

if [[ -f "$ROOT_DIR/Assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if command -v codesign >/dev/null 2>&1; then
  CODESIGN_IDENTITY="${LOCALFLOW_CODESIGN_IDENTITY:--}"
  CODESIGN_KEYCHAIN="${LOCALFLOW_CODESIGN_KEYCHAIN:-}"
  CODESIGN_REQUIREMENTS="${LOCALFLOW_CODESIGN_REQUIREMENTS:-=designated => identifier \"local.localflow.app\"}"

  codesign_args=(--force --deep --sign "$CODESIGN_IDENTITY")
  if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  if [[ -n "$CODESIGN_REQUIREMENTS" ]]; then
    codesign_args+=(--requirements "$CODESIGN_REQUIREMENTS")
  fi

  codesign "${codesign_args[@]}" "$APP_DIR" >/dev/null 2>&1 \
    || codesign --force --deep --sign - --requirements '=designated => identifier "local.localflow.app"' "$APP_DIR" >/dev/null 2>&1 \
    || true
fi

echo "$APP_DIR"
