#!/usr/bin/env bash
# Usage: set_version.sh <version-string>
# Example: set_version.sh 2.2.0
# Stamps CFBundleShortVersionString and CFBundleVersion in MDViewer/Info.plist.
# The git checkout is mutated in-place; CI never commits this change back.
set -euo pipefail

VERSION="${1:?version required, e.g. 2.2.0}"
PLIST="MDViewer/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "::error::$PLIST not found"
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

echo "Stamped $PLIST: ShortVersionString=$VERSION  Version=$VERSION"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST"
