#!/usr/bin/env bash
# Usage: generate_appcast.sh <version> <dmg-path>
# Produces build/appcast.xml, EdDSA-signed by Sparkle's generate_appcast,
# with MDViewer post-processing injected per-item:
#   - <sparkle:phasedRolloutInterval>43200</sparkle:phasedRolloutInterval>  (12h, SPK-07)
#   - <sparkle:releaseNotesLink>https://github.com/mitgor/mdviewer/releases/tag/v${VERSION}</sparkle:releaseNotesLink>  (SPK-12)
#   - <sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>  (SPK-09 appcast side)
#
# Staging strategy: SINGLE-DMG. We stage only the just-built DMG so the
# output appcast has exactly one <item>. The GitHub Releases page is the
# historical record; Sparkle clients read the latest <item> and do not
# need prior-version items in the appcast. (See Research §6 + §Planning
# Implications; alternative full-history-regeneration or append-to-previous
# strategies are explicitly rejected.)
#
# Key materialisation: the EdDSA private key is streamed through STDIN
# to `generate_appcast --ed-key-file -` and NEVER written to runner disk.
# This avoids Pitfall B (newline introduction during echo/file round-trip)
# and keeps the key out of `ps`, $RUNNER_TEMP, and job logs.
#
# Fallback (NOT active): if a future Sparkle version drops stdin support,
# the tempfile-with-trap pattern is:
#     KEYF=$(mktemp -t sparkle_ed_XXXXXX) && trap 'rm -f "$KEYF"' EXIT
#     printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEYF" && chmod 600 "$KEYF"
#     "$GENERATE_APPCAST" --ed-key-file "$KEYF" …
# Leave as a comment; do not activate unless stdin is removed upstream.
set -euo pipefail

VERSION="${1:?version required (e.g. 2.2.0)}"
DMG_PATH="${2:?dmg path required (e.g. build/MDViewer-2.2.0.dmg)}"

: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY must be set in env}"
[ -f "$DMG_PATH" ] || { echo "::error::$DMG_PATH not found"; exit 1; }

# 1. Locate generate_appcast in DerivedData — path hash varies per-build
#    on hosted runners, so we discover it rather than hardcode.
#    (Pitfall A — hardcoded paths work locally, break in CI.)
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData \
    -type f -name generate_appcast \
    -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/*' 2>/dev/null \
    | head -n1)

if [ -z "$GENERATE_APPCAST" ]; then
  echo "::error::generate_appcast not found in DerivedData."
  echo "::error::Has Sparkle SPM been resolved? build_and_sign.sh should have"
  echo "::error::triggered resolution via 'xcodebuild archive'. Check earlier logs."
  exit 1
fi
chmod +x "$GENERATE_APPCAST"
echo "Found generate_appcast at: $GENERATE_APPCAST"

# 2. Stage the DMG alone in a directory. generate_appcast scans a
#    directory for .dmg / .zip / .pkg / .tar.* files and produces one
#    <item> per file. Single-DMG staging => single-<item> appcast.
STAGING="${RUNNER_TEMP:-/tmp}/appcast-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG_PATH" "$STAGING/"

# 3. Invoke generate_appcast with the private key streamed via stdin.
#    --maximum-deltas 0: MDViewer does not use Sparkle delta updates
#      (per milestone Out-of-Scope list).
#    --link: appcast channel <link> — project landing page.
#    --download-url-prefix: where each <item>'s <enclosure url> points.
mkdir -p build
RAW_APPCAST="${RUNNER_TEMP:-/tmp}/appcast.xml"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
  | "$GENERATE_APPCAST" \
      --ed-key-file - \
      --maximum-deltas 0 \
      --link "https://github.com/mitgor/mdviewer" \
      --download-url-prefix "https://github.com/mitgor/mdviewer/releases/download/v${VERSION}/" \
      -o "$RAW_APPCAST" \
      "$STAGING"

[ -s "$RAW_APPCAST" ] \
  || { echo "::error::generate_appcast produced empty appcast.xml"; exit 1; }

# 4. Post-process: inject phasedRolloutInterval + releaseNotesLink +
#    minimumSystemVersion under each <item>, idempotent (upsert: if a
#    child already exists, set its text; else create).
python3 - "$RAW_APPCAST" "$VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, version = sys.argv[1], sys.argv[2]
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE_NS)
ET.register_namespace('dc', 'http://purl.org/dc/elements/1.1/')

tree = ET.parse(path)
root = tree.getroot()

def upsert(parent, local_name, text):
    qname = '{%s}%s' % (SPARKLE_NS, local_name)
    existing = parent.find(qname)
    if existing is None:
        existing = ET.SubElement(parent, qname)
    existing.text = text

item_count = 0
for item in root.iter('item'):
    upsert(item, 'phasedRolloutInterval', '43200')
    upsert(item, 'releaseNotesLink',
           'https://github.com/mitgor/mdviewer/releases/tag/v%s' % version)
    upsert(item, 'minimumSystemVersion', '13.0.0')
    item_count += 1

if item_count == 0:
    print('::error::No <item> elements found in appcast XML — generate_appcast failed silently?')
    sys.exit(1)

tree.write(path, xml_declaration=True, encoding='utf-8')
print('Post-processed %d <item> element(s) in %s' % (item_count, path))
PY

# 5. Copy to build/ so the workflow's action-gh-release step can upload it.
cp "$RAW_APPCAST" build/appcast.xml

# 6. Sanity-check: the output has at least one <sparkle:edSignature>.
#    If this fails, the key didn't survive the pipe or generate_appcast
#    had a silent error — either way, do NOT upload an unsigned appcast.
grep -q 'sparkle:edSignature' build/appcast.xml \
  || { echo "::error::build/appcast.xml missing EdDSA signature"; exit 1; }

# 7. Sanity-check: our three post-processed elements are present.
for ELEMENT in 'phasedRolloutInterval>43200' 'minimumSystemVersion>13.0.0' "releaseNotesLink>https://github.com/mitgor/mdviewer/releases/tag/v${VERSION}"; do
  grep -q "$ELEMENT" build/appcast.xml \
    || { echo "::error::build/appcast.xml missing post-processed element: $ELEMENT"; exit 1; }
done

echo "Generated build/appcast.xml for v${VERSION}"
