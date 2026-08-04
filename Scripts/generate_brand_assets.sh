#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Assets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.iconset"
RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localflow-brand.XXXXXX")"

cleanup() {
  rm -rf "$RENDER_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
swift build
"$ROOT_DIR/.build/debug/LocalFlow" \
  --render-brand-assets "$RENDER_DIR"

cp "$RENDER_DIR/AppIcon.png" "$ASSETS_DIR/AppIcon.png"
cp "$RENDER_DIR/BrandOrb.png" "$ASSETS_DIR/BrandOrb.png"
cp "$RENDER_DIR/MenuBarOrb.png" "$ASSETS_DIR/MenuBarOrb.png"

mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$RENDER_DIR/CompactAppIcon.png" \
  --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$RENDER_DIR/CompactAppIcon.png" \
  --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$RENDER_DIR/CompactAppIcon.png" \
  --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$RENDER_DIR/CompactAppIcon.png" \
  --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ASSETS_DIR/AppIcon.png" \
  --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" \
  -o "$ASSETS_DIR/AppIcon.icns"

echo "$ASSETS_DIR/AppIcon.icns"
