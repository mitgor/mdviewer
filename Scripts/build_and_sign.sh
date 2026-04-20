#!/usr/bin/env bash
# Usage: build_and_sign.sh <signing-id-sha1> <team-id>
# Produces build/export/MDViewer.app universal (arm64 + x86_64), hardened runtime, signed.
set -euo pipefail

SIGNING_ID="${1:?signing-id (SHA-1) required}"
TEAM_ID="${2:?team-id required}"

# Use a brew-installed xcodegen to regenerate the project from project.yml.
# This guarantees the .xcodeproj on disk matches project.yml even if a developer
# forgot to commit a regen.
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate

mkdir -p build

# Archive — universal binary, hardened runtime, manual signing with SHA-1 identity.
xcodebuild archive \
  -project MDViewer.xcodeproj \
  -scheme MDViewer \
  -configuration Release \
  -archivePath build/MDViewer.xcarchive \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | xcbeautify --renderer github-actions || true

# Export — re-uses ExportOptions.plist at repo root.
xcodebuild -exportArchive \
  -archivePath build/MDViewer.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist \
  | xcbeautify --renderer github-actions || true

# Verify Hardened Runtime is set on the resulting binary (defends against silent
# regression — Pitfall #24 says missing --options runtime is rejected by notary).
codesign -dvvv build/export/MDViewer.app 2>&1 | grep -E "flags=.*runtime" \
  || { echo "::error::Hardened Runtime is NOT enabled on the archive"; exit 1; }

# Verify universal arch (success criterion #2).
APP_BIN="build/export/MDViewer.app/Contents/MacOS/MDViewer"
ARCHS=$(lipo -archs "$APP_BIN")
echo "Built archs: $ARCHS"
if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
  echo "::error::App is not universal (arm64 + x86_64). Got: $ARCHS"
  exit 1
fi

echo "Built build/export/MDViewer.app: signed, hardened, universal"
