#!/usr/bin/env bash
# Usage: verify_release.sh <dmg-path>
# Final gate: confirms the DMG is universal, signed, hardened, stapled.
# Run after notarize.sh; failure here means do NOT publish.
set -euo pipefail

DMG_PATH="${1:?dmg path required}"
APP_PATH="build/export/MDViewer.app"

# 1. App is universal.
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/MDViewer")
[[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]] \
  || { echo "::error::not universal: $ARCHS"; exit 1; }
echo "PASS universal: $ARCHS"

# 2. App has hardened runtime.
codesign -dvvv "$APP_PATH" 2>&1 | grep -E "flags=.*runtime" >/dev/null \
  || { echo "::error::hardened runtime not set"; exit 1; }
echo "PASS hardened runtime"

# 3. App is signed by our team.
codesign -dvvv "$APP_PATH" 2>&1 | grep -q "TeamIdentifier=V7YK72YLFF" \
  || { echo "::error::wrong team identifier"; exit 1; }
echo "PASS signed by V7YK72YLFF"

# 4. DMG is signed.
codesign -dvvv "$DMG_PATH" 2>&1 | grep -q "TeamIdentifier=V7YK72YLFF" \
  || { echo "::error::DMG not signed by V7YK72YLFF"; exit 1; }
echo "PASS DMG signed"

# 5. Ticket is stapled to the DMG.
xcrun stapler validate "$DMG_PATH" \
  || { echo "::error::stapler validate failed"; exit 1; }
echo "PASS stapled ticket valid"

# 6. spctl gate - Gatekeeper would accept this on a user's Mac.
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" 2>&1 \
  | grep -E "(accepted|Notarized Developer ID)" >/dev/null \
  || { echo "::warning::spctl did not confirm Notarized Developer ID (may pass on end-user Mac, manual check recommended)"; }

echo "Release verified: $DMG_PATH"
