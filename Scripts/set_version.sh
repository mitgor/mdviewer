#!/usr/bin/env bash
# Usage: set_version.sh <version-string>
# Example: set_version.sh 2.2.0       -> CFBundleShortVersionString=2.2.0,       CFBundleVersion=220
# Example: set_version.sh 2.2.0-rc.2  -> CFBundleShortVersionString=2.2.0-rc.2, CFBundleVersion=220
#
# Stamps CFBundleShortVersionString (human-visible semver) AND CFBundleVersion
# (monotonic integer derived by strip-dots from the short version) into
# MDViewer/Info.plist. The git checkout is mutated in-place; CI never commits
# this change back.
#
# Scheme (SPK-08 migration; locked in Phase 12 Plan 3):
#   - strip any pre-release suffix ("-rc.2", "-beta.1", etc.) from the
#     version -- the integer reflects the FINAL release number, not the
#     intermediate RC number. rc.1 and rc.2 of 2.2.0 both stamp 220.
#     Rationale: rc tags are pre-release and not reachable via /releases/latest/,
#     so the collision is harmless; simpler than a 5-digit scheme.
#   - remove dots from what's left: 2.2.0 -> 220, 2.10.0 -> 2100, 2.2.10 -> 2210.
#     Monotonic for any X.Y.Z with each component <10000. See Research A3.
set -euo pipefail

VERSION="${1:?version required, e.g. 2.2.0 or 2.2.0-rc.2}"
PLIST="MDViewer/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "::error::$PLIST not found"
  exit 1
fi

# Strip pre-release suffix; then strip dots.
CLEAN_VERSION="${VERSION%%-*}"              # "2.2.0-rc.2" -> "2.2.0"
INTEGER_VERSION="${CLEAN_VERSION//./}"      # "2.2.0" -> "220"

# Sanity-check: result is non-empty and all digits.
if [[ ! "$INTEGER_VERSION" =~ ^[0-9]+$ ]]; then
  echo "::error::Derived integer version is not purely numeric: '$INTEGER_VERSION' (from input '$VERSION')"
  echo "::error::Expected input like '2.2.0' or '2.2.0-rc.2'."
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION"      "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $INTEGER_VERSION"         "$PLIST"

echo "Stamped $PLIST: ShortVersionString=$VERSION  Version=$INTEGER_VERSION"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion"            "$PLIST"
