#!/usr/bin/env bash
# Usage: verify_bundle.sh <app-path> <team-id>
# Pre-notarize bundle-layout smoke test for Phase 12 (Sparkle integration).
# Guards against: SPM double-bundle regression (sparkle-project/Sparkle#1689),
# mismatched team IDs on XPC services (Pitfall #15 — causes runtime XPC
# rejection with no user-visible error), missing XPC services, unstripped
# hardened-runtime, and Plan-3 CFBundleVersion-string regression.
#
# Runs AFTER Scripts/make_dmg.sh (so the .app is signed and the framework
# is embedded) and BEFORE Scripts/notarize.sh (cheaper to fail here than
# after paying the ~5min notarize wait).
set -euo pipefail

APP="${1:?app bundle path required (e.g. build/export/MDViewer.app)}"
TEAM_ID="${2:?team id required (e.g. V7YK72YLFF)}"

[ -d "$APP" ] || { echo "::error::$APP not found or not a directory"; exit 1; }

# 1. Exactly one Sparkle.framework — guards SPM double-bundle (SPK-10).
COUNT=$(find "$APP" -type d -name 'Sparkle.framework' | wc -l | xargs)
if [ "$COUNT" != "1" ]; then
  echo "::error::expected exactly 1 Sparkle.framework in $APP, found $COUNT"
  find "$APP" -type d -name 'Sparkle.framework'
  exit 1
fi
echo "PASS 1x Sparkle.framework"

# 2. Framework is at the standard path.
FW="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FW" ] || { echo "::error::Sparkle.framework not at $FW"; exit 1; }
echo "PASS Sparkle.framework at Contents/Frameworks/"

# 3+4. XPC services present inside the framework.
XPC_BASE="$FW/Versions/B/XPCServices"
for XPC in Installer Downloader; do
  [ -d "$XPC_BASE/${XPC}.xpc" ] \
    || { echo "::error::${XPC}.xpc missing at $XPC_BASE/${XPC}.xpc"; exit 1; }
done
echo "PASS Installer.xpc + Downloader.xpc present"

# 5. Consistent team ID across app + framework + XPCs (Pitfall #15).
# Mismatched team IDs on XPC services cause Sparkle 2's hardened XPC policy
# to reject the update at runtime with no user-visible error.
for CHECK in \
  "$APP" \
  "$FW" \
  "$XPC_BASE/Installer.xpc" \
  "$XPC_BASE/Downloader.xpc"; do
  codesign -dvvv "$CHECK" 2>&1 | grep -q "TeamIdentifier=${TEAM_ID}" \
    || { echo "::error::wrong team identifier on $CHECK (expected $TEAM_ID)"; exit 1; }
done
echo "PASS consistent team identifier $TEAM_ID across app+framework+xpcs"

# 6. Hardened runtime on app and framework.
for CHECK in "$APP" "$FW"; do
  codesign -dvvv "$CHECK" 2>&1 | grep -qE "flags=.*runtime" \
    || { echo "::error::hardened runtime not set on $CHECK"; exit 1; }
done
echo "PASS hardened runtime on app + framework"

# 7. Required Sparkle Info.plist keys present.
PLIST="$APP/Contents/Info.plist"
for KEY in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval; do
  /usr/libexec/PlistBuddy -c "Print :$KEY" "$PLIST" >/dev/null 2>&1 \
    || { echo "::error::$PLIST missing required Sparkle key: $KEY"; exit 1; }
done
echo "PASS required Sparkle Info.plist keys present"

# 8. CFBundleVersion is a pure integer (SPK-08 gate — guards Plan 3 regression).
# Sparkle compares CFBundleVersion lexicographically; a dotted-string like
# "2.10" sorts LESS THAN "2.9" which would cause a downgrade scenario.
CFB_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
if [[ ! "$CFB_VER" =~ ^[0-9]+$ ]]; then
  echo "::error::CFBundleVersion is not a pure integer: '$CFB_VER'"
  echo "::error::Sparkle compares CFBundleVersion lexicographically — this would break updates."
  echo "::error::See SPK-08 in .planning/REQUIREMENTS.md and Plan 12-03 migration task."
  exit 1
fi
echo "PASS CFBundleVersion=$CFB_VER (integer)"

echo "Bundle verified: $APP"
