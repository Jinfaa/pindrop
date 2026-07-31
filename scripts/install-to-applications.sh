#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Pindrop"
CONFIGURATION="${1:-Debug}"
DEST="${2:-/Applications}"
APP_SRC="DerivedData/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
APP_DST="${DEST}/${APP_NAME}.app"

if command -v just >/dev/null 2>&1; then
  if [ "$CONFIGURATION" = "Release" ]; then
    just build-release-unsigned
  else
    just build-unsigned
  fi
else
  echo "just not found; using xcodebuild"
  SIGNING='CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO'
  # shellcheck disable=SC2086
  xcodebuild \
    -project Pindrop.xcodeproj \
    -scheme Pindrop \
    -configuration "$CONFIGURATION" \
    -derivedDataPath DerivedData \
    -skipPackagePluginValidation \
    $SIGNING \
    build
fi

if [ ! -d "$APP_SRC" ]; then
  echo "App not found: $APP_SRC" >&2
  exit 1
fi

echo "Installing ${APP_SRC} -> ${APP_DST}"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
echo "Done: ${APP_DST}"
open -R "$APP_DST"
