#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

cd "$ROOT_DIR/apps/island-native"

: "${CROW_ISLAND_SCREEN:=builtin}"
export CROW_ISLAND_SCREEN

swift build
BUILD_DIR="$(swift build --show-bin-path)"

APP_DIR="$ROOT_DIR/apps/island-native/build/CrowIslandNative.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/CrowIslandNative" "$MACOS_DIR/CrowIslandNative"
cp "$ROOT_DIR/apps/island-native/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

exec /usr/bin/open -n -W "$APP_DIR"
