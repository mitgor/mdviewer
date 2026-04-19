#!/usr/bin/env bash
# Usage: import_cert.sh <team-id>
# Discovers the SHA-1 of a Developer ID Application cert matching the team ID,
# disambiguating the case where multiple certs share the CN (Pitfall #1).
# Writes signing_id=<sha1> to $GITHUB_OUTPUT and stdout.
set -euo pipefail

TEAM_ID="${1:?team id required}"

echo "All codesigning identities visible in the search list:"
security find-identity -v -p codesigning

# Filter by team ID (the (V7YK72YLFF) suffix in the CN), pick the FIRST valid match.
# `security find-identity -v` only lists non-expired identities, so this naturally
# excludes the older expired cert if any.
SIGNING_ID=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "($TEAM_ID)" \
  | head -n1 \
  | awk '{print $2}')

if [ -z "$SIGNING_ID" ]; then
  echo "::error::No valid Developer ID Application cert found for team $TEAM_ID"
  echo "Available identities:"
  security find-identity -v -p codesigning
  exit 1
fi

# Sanity check: must be exactly 40 hex digits (codesign(1) treats this as a SHA-1)
if [[ ! "$SIGNING_ID" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "::error::Discovered SIGNING_ID is not a 40-char hex SHA-1: $SIGNING_ID"
  exit 1
fi

echo "Selected signing identity SHA-1: $SIGNING_ID"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "signing_id=$SIGNING_ID" >> "$GITHUB_OUTPUT"
fi
