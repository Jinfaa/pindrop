#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Pindrop"
CONFIGURATION="${1:-Debug}"
DEST="${2:-/Applications}"
APP_SRC="DerivedData/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
APP_DST="${DEST}/${APP_NAME}.app"

# Signed with the project's Apple Development identity so macOS keeps
# microphone and Accessibility grants across reinstalls.
xcodebuild \
  -project Pindrop.xcodeproj \
  -scheme Pindrop \
  -configuration "$CONFIGURATION" \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  build

if [ ! -d "$APP_SRC" ]; then
  echo "App not found: $APP_SRC" >&2
  exit 1
fi

echo "Installing ${APP_SRC} -> ${APP_DST}"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
echo "Done: ${APP_DST}"
open -R "$APP_DST"
