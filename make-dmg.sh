#!/bin/bash
# Build JustGetIt (Release, ad-hoc signed) and package it as a DMG.
# Ad-hoc signing is fine for local use. No Developer ID or notarization needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="JustGetIt"
BUILD="build"
STAGE="$BUILD/dmg"
DMG="$APP.dmg"

xcodegen generate

xcodebuild \
  -project "$APP.xcodeproj" \
  -scheme "$APP" \
  -configuration Release \
  -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  clean build

APP_PATH="$BUILD/Build/Products/Release/$APP.app"
[ -d "$APP_PATH" ] || { echo "error: $APP_PATH not found"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"   # create-dmg adds the Applications drop-link itself

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not found. Install with: brew install create-dmg"
  exit 1
fi

create-dmg \
  --volname "$APP" \
  --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "$APP.app" 150 195 \
  --app-drop-link 390 195 \
  --hide-extension "$APP.app" \
  --hdiutil-quiet \
  --overwrite \
  "$DMG" "$STAGE"

echo "Built $DMG. Open it and drag $APP to Applications."
