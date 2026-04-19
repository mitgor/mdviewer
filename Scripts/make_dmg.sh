#!/usr/bin/env bash
# Usage: make_dmg.sh <signing-id-sha1> <version>
# Produces build/MDViewer-<version>.dmg, signed with the same identity as the .app.
set -euo pipefail

SIGNING_ID="${1:?signing-id required}"
VERSION="${2:?version required}"

APP_PATH="build/export/MDViewer.app"
DMG_PATH="build/MDViewer-${VERSION}.dmg"
STAGING="build/dmg-staging"

[ -d "$APP_PATH" ] || { echo "::error::$APP_PATH not found - run build_and_sign.sh first"; exit 1; }

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# UDZO format is what notarytool accepts and what stapler tickets reference.
# Pitfall #7: do NOT convert format between submit and staple - cdhash will change.
hdiutil create \
  -volname "MDViewer ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Sign the DMG itself (notarytool requires a signed container - STACK.md sec 7).
codesign --force --sign "$SIGNING_ID" --timestamp "$DMG_PATH"

# Sanity-check the DMG signature.
codesign -dvvv "$DMG_PATH" 2>&1 | grep "TeamIdentifier=V7YK72YLFF" \
  || { echo "::error::DMG signature missing or wrong team"; exit 1; }

echo "Built and signed $DMG_PATH"
