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
mkdir -p "$CONTENTS_DIR/Resources"
cp Resources/AppIcon.icns Resources/MenuBarGlyph.png Resources/MenuBarGlyph@2x.png Resources/IslandGlyph.png "$CONTENTS_DIR/Resources/"
chmod +x "$MACOS_DIR/CrowMac"

# macOS ties Accessibility and Screen Recording grants to the app's signature. An
# ad-hoc signature changes with every build, so grants would silently stop working
# after each rebuild. Sign with a stable identity: CROW_CODESIGN_IDENTITY, else the
# first Apple Development certificate that is not revoked (macOS kills apps signed
# with a revoked certificate at launch; "rejected" only means not notarized).
sign_with() {
  codesign --force --sign "$1" --identifier ai.crow.mac "$BUNDLE_DIR" >/dev/null 2>&1 || return 1
  local assessment
  assessment="$(spctl --assess --type execute "$BUNDLE_DIR" 2>&1 || true)"
  [[ "$assessment" != *REVOKED* ]]
}
SIGNED=""
if [[ -n "${CROW_CODESIGN_IDENTITY:-}" ]]; then
  sign_with "$CROW_CODESIGN_IDENTITY" && SIGNED="$CROW_CODESIGN_IDENTITY"
else
  while read -r candidate; do
    if sign_with "$candidate"; then
      SIGNED="$candidate"
      break
    fi
  done < <(security find-identity -p codesigning -v 2>/dev/null | grep -v CSSMERR | grep -E '"Apple Development:' | awk '{print $2}')
fi
if [[ -n "$SIGNED" ]]; then
  echo "Signed CrowMac.app with ${SIGNED:0:8}…"
else
  codesign --force --sign - --identifier ai.crow.mac "$BUNDLE_DIR" >/dev/null
  echo "warning: no usable signing identity; Accessibility and Screen Recording must be granted again after every build" >&2
fi

open "$BUNDLE_DIR"
