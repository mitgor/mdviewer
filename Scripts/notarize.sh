#!/usr/bin/env bash
# Usage: notarize.sh <dmg-path>
# Reads ASC_API_KEY_P8_BASE64, ASC_API_KEY_ID, ASC_API_ISSUER_ID from env.
# Submits to notarytool with --wait --timeout 25m. On failure, fetches the
# detailed JSON log and writes it to build/notarytool-log.json. On success,
# staples the ticket to the DMG.
set -euo pipefail

DMG_PATH="${1:?dmg path required}"
[ -f "$DMG_PATH" ] || { echo "::error::$DMG_PATH not found"; exit 1; }

: "${ASC_API_KEY_P8_BASE64:?must be set}"
: "${ASC_API_KEY_ID:?must be set}"
: "${ASC_API_ISSUER_ID:?must be set}"

# Pitfall #13: the .p8 must be base64 in the secret to survive newline normalization.
# Decode to a tmp file (notarytool wants a file path). Trap removes it on any exit.
P8_PATH=$(mktemp -t asc_key_XXXXXX)
trap 'rm -f "$P8_PATH"' EXIT INT TERM
echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$P8_PATH"
chmod 600 "$P8_PATH"

# Sanity check: the decoded key should start with the PEM marker.
head -n1 "$P8_PATH" | grep -q "BEGIN PRIVATE KEY" \
  || { echo "::error::ASC_API_KEY_P8_BASE64 did not decode to a valid PEM file"; exit 1; }

mkdir -p build
SUBMIT_LOG="build/notarytool-submit.json"

set +e
xcrun notarytool submit "$DMG_PATH" \
  --key      "$P8_PATH" \
  --key-id   "$ASC_API_KEY_ID" \
  --issuer   "$ASC_API_ISSUER_ID" \
  --wait \
  --timeout 25m \
  --output-format json \
  | tee "$SUBMIT_LOG"
SUBMIT_RC=$?
set -e

# Submission ID lives in the JSON regardless of accept/reject status.
SUBMISSION_ID=$(jq -r '.id // empty' "$SUBMIT_LOG")
STATUS=$(jq -r '.status // "Unknown"' "$SUBMIT_LOG")

echo "Notarization submission ID: $SUBMISSION_ID"
echo "Notarization status:        $STATUS"

if [ -z "$SUBMISSION_ID" ]; then
  echo "::error::No submission ID in notarytool output (network failure? Apple notary outage? - Pitfall #8)"
  exit 1
fi

# Pitfall #4: top-level "Invalid" status comes with empty statusMessage.
# The detailed errors are in `notarytool log` - always fetch on non-Accepted.
if [ "$STATUS" != "Accepted" ]; then
  echo "::warning::Notarization not Accepted - fetching detailed log"
  xcrun notarytool log "$SUBMISSION_ID" \
    --key      "$P8_PATH" \
    --key-id   "$ASC_API_KEY_ID" \
    --issuer   "$ASC_API_ISSUER_ID" \
    build/notarytool-log.json || true
  echo "::error::Notarization rejected. See build/notarytool-log.json (uploaded as artifact)"
  exit "$SUBMIT_RC"
fi

# Pitfall #7: do NOT modify the DMG between here and stapling.
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Notarized + stapled: $DMG_PATH"
