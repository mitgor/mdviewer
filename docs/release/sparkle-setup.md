# Sparkle Setup Runbook (MDViewer)

Operator-facing runbook for Sparkle auto-update key management. Use this
document for:

- **First-time setup** (Phase 12 Plan 03 Task 3 ritual — already performed
  once on 2026-04-20; this doc captures what happened so future operators
  can reproduce).
- **Key rotation** (see also `ci-secrets.md` SPARKLE_ED_PRIVATE_KEY
  §Rotation procedure).
- **Disaster recovery** (if the developer Mac dies or the primary offline
  backup is lost — restore from the remaining custody copy).

This doc does NOT cover:

- Phase 12 Plan 01 (app-side Sparkle wiring — `SPUStandardUpdaterController`,
  Info.plist keys, "Check for Updates…" menu item) — see `12-01-SUMMARY.md`.
- Phase 12 Plan 02 (CI appcast pipeline — `verify_bundle.sh` +
  `generate_appcast.sh` + the release.yml step wiring) — see
  `12-02-SUMMARY.md`.
- Apple-side signing/notarization (Developer ID, App Store Connect Team
  API Key, notarytool) — see `docs/release/ci-secrets.md` ACTIVE sections.

---

## When to run the key-generation ritual

**Once per project lifetime.** Already performed in Phase 12 Plan 03
Task 3 on 2026-04-20.

Reasons you might re-run:

- **Key rotation after suspected compromise.** See
  `docs/release/ci-secrets.md` §Rotation procedure — requires dual-key
  overlap across an 18-month window. NOT a drop-in swap; every existing
  install has the OLD public key baked in and will refuse signatures from
  the new private key until you ship a build carrying both keys.
- **Disaster recovery.** The developer Mac is lost AND the offline backup
  is also lost AND the GitHub Secret copy is also lost. This is the
  catastrophic scenario: a fresh keypair can only reach users who install
  a NEW release, and that release cannot auto-update existing installs —
  a manual-download callout (see `README.md`) is the only recovery path.
  Regenerate only after confirming this has actually happened.

Do NOT re-run on every release, milestone, or as routine hygiene. The
public key is baked into every shipped `Info.plist` — a fresh keypair
means every existing install becomes un-updatable via the current auto-
update flow.

---

## Prerequisites

1. **Phase 12 Plan 01 merged.** Sparkle 2.9.1 is an SPM dependency of
   MDViewer. Verify via `grep -q 'package: Sparkle' project.yml`.
2. **Sparkle locally resolved.** Run
   `xcodebuild -project MDViewer.xcodeproj -scheme MDViewer -resolvePackageDependencies`
   once so the Sparkle binaries appear in DerivedData under
   `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.
3. **Admin access to `mitgor/mdviewer`** for the GitHub Secrets UI:
   <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
4. **At least one operator-controlled offline backup medium** — encrypted
   USB in a safe, YubiKey PIV slot, paper printout, or a password-manager
   vault YOU personally control (not a shared/org vault). TWO independent
   offline media is the ideal; one is the currently-accepted minimum (see
   `ci-secrets.md` §Single-offline-backup configuration).

---

## Procedure

### 1. Locate `generate_keys`

```bash
GEN_KEYS=$(find ~/Library/Developer/Xcode/DerivedData \
    -name generate_keys \
    -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/*' | head -n1)
echo "$GEN_KEYS"
```

If empty, SPM isn't resolved — re-run the Prereq step 2.

### 2. Generate the pair

```bash
"$GEN_KEYS"
```

Keychain Access prompts you to allow saving the private key into your
login Keychain. Choose "Always Allow" (so future local `generate_appcast`
runs can sign without re-prompting).

Stdout prints the public key (44 characters of base64 ending with `=`).
Copy it verbatim.

**Note on size.** As of Sparkle 2.9.1 the public key is 44 characters
(a 32-byte Ed25519 scalar, base64-encoded without padding overhead). If
you see a longer blob (88+ chars, PEM `-----BEGIN…` header, etc.),
something is wrong — verify your Sparkle pin.

### 3. Install the public key in Info.plist

```bash
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey <44-char-key>" MDViewer/Info.plist
git add MDViewer/Info.plist
git commit -m "feat: install SUPublicEDKey in Info.plist"
```

Single-line change. Keep this commit atomic for reviewability.

### 4. Export the private key

```bash
cd ~
"$GEN_KEYS" -x sparkle_private_key.txt
cat sparkle_private_key.txt     # single line of base64
wc -c sparkle_private_key.txt   # expect ~44 bytes (Sparkle 2.9.1); older docs may say 88–89
```

### 5. Install as GitHub Secret

```bash
cat sparkle_private_key.txt | pbcopy
open "https://github.com/mitgor/mdviewer/settings/secrets/actions"
```

- New secret or Update: name `SPARKLE_ED_PRIVATE_KEY`, value = pasted
  clipboard. The paste input preserves the bytes exactly; do NOT add a
  trailing newline manually.
- Verify:
  ```bash
  gh secret list --repo mitgor/mdviewer | grep SPARKLE_ED_PRIVATE_KEY
  ```

### 6. Offline backup(s)

Copy `~/sparkle_private_key.txt` to one or more offline locations:

- **Primary (minimum required):** a physical medium or password manager
  that YOU personally control. Examples: encrypted APFS USB in a home
  safe, YubiKey PIV slot, 1Password Personal vault, paper printout in a
  locked drawer.
- **Secondary (recommended; not yet configured in this project):** a
  second, independent offline medium of a DIFFERENT kind (e.g. if Primary
  is a USB drive, make Secondary a password-manager vault so a single
  physical-theft event does not take out both copies).

**Do NOT use** for either backup:

- Shared / corporate vaults
- Cloud sync (Dropbox, iCloud, OneDrive, Google Drive)
- Email-to-self
- Chat apps (Slack, Signal-to-yourself, iMessage)
- Git (any repo, public or private)

### 7. Update `docs/release/ci-secrets.md`

Fill in the `Primary backup location` and (if configured) `Secondary
backup location` lines in the SPARKLE_ED_PRIVATE_KEY section with the
LOCATIONS — never the key bytes.

Add or update the `### Provenance` subsection: generation date, key
format note, Info.plist commit SHA, GitHub Secret install timestamp,
Keychain entry note, plaintext-export deletion confirmation.

Commit. The current state (as of 2026-04-20) shows ONE offline backup
and explicitly documents the single-offline deviation from the plan.

### 8. Delete the plaintext

```bash
rm ~/sparkle_private_key.txt
# Verify not in Trash either:
ls ~/.Trash 2>/dev/null | grep sparkle || echo "not in Trash"
```

The private key remains in your login Keychain and in the offline
backup(s). Safe to delete the plaintext export now.

### 9. Verify the Keychain entry

Open Keychain Access.app → search "Sparkle". The entry labelled
`"Private key for signing Sparkle updates"` (service
`https://sparkle-project.org`) MUST exist — `generate_appcast` needs it
for future local testing (e.g. running `Scripts/generate_appcast.sh` on
the developer Mac against a locally-built DMG, without the GitHub Secret
round-trip).

---

## CFBundleVersion scheme (Phase 12 Plan 03 Tasks 1-2)

Sparkle compares `CFBundleVersion` **lexicographically** (see
`PITFALLS.md` #19). A dotted-string like `"2.10"` sorts BEFORE `"2.9"`
in ASCII, which breaks updates the moment a minor version exceeds 9.
MDViewer's scheme avoids the trap:

- `CFBundleShortVersionString` = human-visible semver:
  `2.2.0`, `2.2.1`, `2.10.0`, `2.2.0-rc.2`
- `CFBundleVersion` = strip-dots integer (strip any `-rc.N` suffix first,
  then remove dots):
  - `2.2.0` → `220`
  - `2.2.1` → `221`
  - `2.10.0` → `2100`
  - `2.2.0-rc.2` → `220` (same as the final 2.2.0)

Why strip-dots (not `git rev-list --count`): simpler (one substitution),
human-readable, monotonic for any X.Y.Z with each component <10000
(Research Assumption A3). No git-history dependency in CI. RC collisions
are accepted (`rc.1` and `rc.2` both stamp `220`) because RC tags are
pre-release and not served from `/releases/latest/download/appcast.xml`.

The scheme is implemented in `Scripts/set_version.sh` and applied by CI
at build time. The baseline `MDViewer/Info.plist` checked-in value is
always an integer (`220` as of 2026-04-20); CI stamps over it per-tag.

**Irreversible:** once `v2.2.0` ships with `CFBundleVersion=220`, every
future release must be a LARGER integer or Sparkle refuses to install.

---

## Rotation procedure (summary; see ci-secrets.md for full detail)

Rotation is NOT a drop-in swap. The MDViewer Sparkle key is an 18-month
dual-key operation:

1. Generate a new key pair (repeat steps 1–9 above, but do NOT yet
   overwrite the Info.plist key or the GitHub Secret).
2. Add the NEW public key to `Info.plist` as a second `SUPublicEDKey`
   entry — Sparkle 2.x accepts a comma-separated list.
3. Ship a release whose `Info.plist` carries BOTH old and new public
   keys. Appcast continues to be signed with the OLD private key.
4. After ≥1 release cycle with both keys shipped and confirmed installed
   on most user bases, switch appcast signing to the NEW private key
   (update the GitHub Secret).
5. Wait at least 18 months (giving slow-upgrading users time to land on
   a dual-key build).
6. Drop the OLD public key from `Info.plist` in a later release.
7. Revoke the old private key from GitHub Secrets and destroy all offline
   backups of it ONLY after step 6 ships.

Full procedure and rationale: `docs/release/ci-secrets.md`
§SPARKLE_ED_PRIVATE_KEY §Rotation procedure.

---

## See also

- `docs/release/ci-secrets.md` — full secrets inventory, provenance,
  rotation, loss-impact per secret, single-offline-backup deviation.
- `.planning/phases/12-sparkle-auto-update-integration/12-RESEARCH.md`
  §Code Examples — minimal working appcast XML.
- `Scripts/generate_appcast.sh` — the CI-side equivalent of this manual
  procedure (no-Keychain stdin path, reads the GitHub Secret).
- `Scripts/verify_bundle.sh` — bundle-layout invariants checked on
  every CI run (including the integer-CFBundleVersion regex).
- Sparkle upstream: <https://sparkle-project.org/documentation/publishing/>.
