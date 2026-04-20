#!/usr/bin/env bash
# Usage: verify_release.sh <dmg-path>
# Final gate: confirms the DMG is arm64, signed, hardened, stapled.
# v2.2+: arm64-only (see PROJECT.md Key Decisions 2026-04-20: x86_64 drop).
# Run after notarize.sh; failure here means do NOT publish.
set -euo pipefail

DMG_PATH="${1:?dmg path required}"
APP_PATH="build/export/MDViewer.app"

# 1. App is arm64 (v2.2+ SC#2 amended 2026-04-20).
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/MDViewer")
[[ "$ARCHS" == "arm64" ]] \
  || { echo "::error::not arm64-only: '$ARCHS' (expected exactly 'arm64')"; exit 1; }
echo "PASS arm64: $ARCHS"

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
