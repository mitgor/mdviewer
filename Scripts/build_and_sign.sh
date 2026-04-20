#!/usr/bin/env bash
# Usage: build_and_sign.sh <signing-id-sha1> <team-id>
# Produces build/export/MDViewer.app arm64, hardened runtime, signed.
# v2.2+: arm64-only (see PROJECT.md Key Decisions 2026-04-20: x86_64 drop).
# Xcode 26.2 on macos-26 runners ships no x86_64 prebuilt swiftmodules for the
# internal stdlib (_DarwinFoundation2/3, _SwiftConcurrencyShims, simd), and
# forcing implicit-module rebuilds hit "redefinition of module 'cmark_gfm'"
# — toolchain-level, not a code-level, issue. Evidence: workflow runs
# 24688263027 (rc.3) and 24688479386 (rc.4).
set -euo pipefail

SIGNING_ID="${1:?signing-id (SHA-1) required}"
TEAM_ID="${2:?team-id required}"

# Use a brew-installed xcodegen to regenerate the project from project.yml.
# This guarantees the .xcodeproj on disk matches project.yml even if a developer
# forgot to commit a regen.
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate

mkdir -p build

# Archive — arm64, hardened runtime, manual signing with SHA-1 identity.
xcodebuild archive \
  -project MDViewer.xcodeproj \
  -scheme MDViewer \
  -configuration Release \
  -archivePath build/MDViewer.xcarchive \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64" \
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

# Verify arm64 arch (v2.2+ Success Criterion #2, amended 2026-04-20).
APP_BIN="build/export/MDViewer.app/Contents/MacOS/MDViewer"
ARCHS=$(lipo -archs "$APP_BIN")
echo "Built archs: $ARCHS"
if [[ "$ARCHS" != "arm64" ]]; then
  echo "::error::App is not arm64-only. Got: '$ARCHS' (expected exactly 'arm64')."
  exit 1
fi

echo "Built build/export/MDViewer.app: signed, hardened, arm64"
