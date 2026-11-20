#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
BUNDLE_DIR="$APP_DIR/build/CrowMac.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$APP_DIR"
swift build

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/debug/CrowMac" "$MACOS_DIR/CrowMac"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/CrowMac"

open "$BUNDLE_DIR"
