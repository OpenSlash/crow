#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/apps/status-native"

swift build
BUILD_DIR="$(swift build --show-bin-path)"

APP_DIR="$ROOT_DIR/apps/status-native/build/CrowStatusNative.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/CrowStatusNative" "$MACOS_DIR/CrowStatusNative"
cp "$ROOT_DIR/apps/status-native/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

exec /usr/bin/open -n -W "$APP_DIR"

