#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Swift:"
swift --version | head -n 1

echo
echo "Xcode:"
xcodebuild -version | head -n 2

echo
if [[ -f "$ROOT_DIR/.env" ]]; then
  if grep -q '^OPENAI_API_KEY=sk-' "$ROOT_DIR/.env"; then
    echo ".env: OPENAI_API_KEY found"
  else
    echo ".env: present, but OPENAI_API_KEY does not look set"
  fi
else
  echo ".env: missing. Copy .env.example to .env and set OPENAI_API_KEY."
fi

echo
if [[ -f "$ROOT_DIR/Config/dictionary.json" ]]; then
  echo "Dictionary: Config/dictionary.json"
else
  echo "Dictionary: using Config/dictionary.example.json until you create Config/dictionary.json"
fi

echo
echo "App bundle after build:"
echo "${LOCALFLOW_BUNDLE_OUTPUT_DIR:-${TMPDIR:-/tmp}/LocalFlow-build/release}/LocalFlow.app"
