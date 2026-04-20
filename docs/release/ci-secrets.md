# CI Release Secrets — Operator Runbook

This document is the canonical source of truth for every secret consumed by
`.github/workflows/release.yml` (Phase 11) and the planned Sparkle / Homebrew
extensions in Phases 12 and 13. If you are setting up the CI release pipeline
from scratch, work through every section in order.

**Audience:** the human operating the `mitgor/mdviewer` repo. Likely only one
person (the developer). The detail level assumes you may be doing this once
every 18 months — written for the rotation case, not the repeat case.

**Status legend in section headers:**
- ACTIVE — consumed by the current `release.yml` (Phase 11)
- PHASE 12 — will be consumed once Sparkle integration ships
- PHASE 13 — will be consumed once Homebrew cask ships

---

## Quick start

1. Open <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. Work through every ACTIVE section below. For each: generate the secret per
   "How to generate", install via "How to install" with the exact name in the
   section header.
3. Before cutting a real `v*` tag, run a `v*-rc.*` dry-run (Plan 11-02 Task 3).
   If the dry-run produces a stapled DMG attached to a draft pre-release, all
   ACTIVE secrets are correctly installed.
4. PHASE 12 and PHASE 13 secrets can wait until those phases land — they will
   not break the current workflow.

---

## Inventory

| Secret name | Status | Purpose |
|---|---|---|
| `MAC_CERT_P12_BASE64` | ACTIVE | Developer ID Application cert + private key (base64-encoded .p12) |
| `MAC_CERT_P12_PASSWORD` | ACTIVE | Password used during the .p12 export |
| `KEYCHAIN_PASSWORD` | ACTIVE | Throwaway password for the per-run CI keychain |
| `APPLE_TEAM_ID` | ACTIVE | `V7YK72YLFF` (Woodenshark LLC) |
| `ASC_API_KEY_ID` | ACTIVE | 10-char Key ID from App Store Connect Team API Key |
| `ASC_API_ISSUER_ID` | ACTIVE | UUID Issuer ID for the Team API Key |
| `ASC_API_KEY_P8_BASE64` | ACTIVE | base64 of the AuthKey_*.p8 file (one-time download) |
| `SPARKLE_ED_PRIVATE_KEY` | PHASE 12 | EdDSA private key for signing appcast updates |
| `HOMEBREW_TAP_PAT` | PHASE 13 | Fine-grained PAT for the homebrew-tap repo |

---

## `MAC_CERT_P12_BASE64`  (ACTIVE)

**Purpose:** base64-encoded `.p12` containing the "Developer ID Application:
Woodenshark LLC (V7YK72YLFF)" certificate AND its private key. Imported by
`Apple-Actions/import-codesign-certs` into a per-run ephemeral keychain.

### How to generate

1. On the developer Mac (the one with the keychain holding the cert), open
   Keychain Access.
2. Search for "Developer ID Application". You will likely see TWO certs with
   the same CN — that is expected (PROJECT.md notes both are valid; the
   workflow disambiguates by SHA-1 at runtime via `Scripts/import_cert.sh`).
   Pick the NEWER one (longer expiration date).
3. Right-click → Export → set format to "Personal Information Exchange
   (.p12)" → save as `mdviewer-developer-id.p12`.
4. Set a strong password when prompted. **Save this password** — it goes into
   `MAC_CERT_P12_PASSWORD` next.
5. base64-encode the .p12:
   ```bash
   base64 -i mdviewer-developer-id.p12 | pbcopy
   ```
   Your clipboard now holds the value to paste into the GitHub Secret.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. Click "New repository secret".
3. Name: `MAC_CERT_P12_BASE64` (exact, case-sensitive).
4. Value: paste from clipboard.
5. Click "Add secret".

### Role / scope minimum

- The cert must be of type "Developer ID Application" (not "Developer ID
  Installer", not "Apple Distribution"). Notary will reject other types.
- It must NOT be expired. `security find-identity -v` only lists non-expired
  certs; `Scripts/import_cert.sh` relies on this.

### Rotation procedure

Triggers for rotation:
- Cert is approaching expiry (~6 months before — Apple Developer ID certs are
  typically valid for 5 years).
- The `.p12` password leaks (re-export with a new password, replace both
  `MAC_CERT_P12_BASE64` and `MAC_CERT_P12_PASSWORD`).
- The cert is revoked from the Apple Developer portal.

Rotation steps:
1. If the existing cert is not expired/revoked, generate a NEW Developer ID
   Application cert in the Apple Developer portal (Keychain Access → Certificate
   Assistant → Request a Certificate from a CA → upload the CSR to
   developer.apple.com → download → install).
2. Repeat the export above with the new cert.
3. Update both `MAC_CERT_P12_BASE64` and `MAC_CERT_P12_PASSWORD` in the same
   sitting (atomic).
4. Run a dry-run with a fresh `v*-rc.*` tag to confirm the new cert signs
   correctly. Both certs will live in the runner keychain during the overlap
   period; `Scripts/import_cert.sh` picks the first valid match — verify it
   picks the new one by checking `signing_id` output in the workflow log.

### Consequences of loss

LOW. The `.p12` is a re-exportable backup of a cert that lives in the developer
Mac's keychain. If the secret is lost (deleted by accident, repo deletion), the
developer can re-export from the keychain and reinstall. **However, if the
keychain copy is ALSO lost** (e.g. dev Mac wiped + no Time Machine backup):
- Generate a new cert in the Apple Developer portal (free, takes ~5 minutes).
- Note: a new cert means a new SHA-1, so any pinned references break — but the
  workflow does not pin, it discovers per run. Self-healing.
- Existing notarized DMGs remain notarized; only future builds need re-signing.

---

## `MAC_CERT_P12_PASSWORD`  (ACTIVE)

**Purpose:** the password set during step 4 of the `.p12` export above. Used by
`Apple-Actions/import-codesign-certs` to unlock the `.p12` before importing
the contained cert + private key into the ephemeral keychain.

### How to generate

It's whatever password you typed when exporting the `.p12`. If you forget it,
you'll have to re-export with a fresh password (and re-update
`MAC_CERT_P12_BASE64` to match).

If generating fresh: `openssl rand -base64 24 | pbcopy` produces a strong one
to paste into the Keychain Access export dialog.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `MAC_CERT_P12_PASSWORD` → paste → Add.

### Role / scope minimum

Symmetric secret; protects the `.p12` blob at rest until it reaches the runner.
No external scope.

### Rotation procedure

Always rotate together with `MAC_CERT_P12_BASE64`. Re-export the cert from
Keychain Access with a new password, base64-encode the new `.p12`, update both
secrets in the same sitting.

### Consequences of loss

LOW. If lost, re-export the `.p12` with a new password from the developer-Mac
keychain. Both secrets stay in lockstep.

---

## `KEYCHAIN_PASSWORD`  (ACTIVE)

**Purpose:** random per-run password for the throwaway CI keychain that
`Apple-Actions/import-codesign-certs` creates. The keychain is destroyed at
job teardown — this password protects nothing of long-term value.

### How to generate

```bash
openssl rand -base64 32 | pbcopy
```

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `KEYCHAIN_PASSWORD` → paste → Add.

### Role / scope minimum

None. Plain symmetric secret used only inside the GitHub-hosted runner during
a single job. Never leaves the runner; never persists.

### Rotation procedure

Rotate annually as hygiene (`openssl rand -base64 32 | pbcopy`, paste into the
GitHub Secrets UI as the new value). No coordinated change with any other
secret needed.

### Consequences of loss

NONE. The keychain it protects is destroyed at job teardown. If the secret is
deleted from the repo, the next workflow run will fail at the cert-import step
— just regenerate per "How to generate" above.

---

## `APPLE_TEAM_ID`  (ACTIVE)

**Purpose:** the 10-char Apple Developer team ID `V7YK72YLFF` (Woodenshark
LLC). Used by `Scripts/import_cert.sh` to filter `security find-identity`
output and disambiguate the two same-CN certs (Pitfall #1). Also passed to
`xcodebuild` as `DEVELOPMENT_TEAM`.

### How to generate

Not strictly secret — public information. Find at:
<https://developer.apple.com> → Account → Membership → Team ID.

For this repo: **`V7YK72YLFF`** (Woodenshark LLC).

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `APPLE_TEAM_ID` → paste `V7YK72YLFF` → Add.

It's stored as a secret for symmetry with the other Apple credentials, not
because the value is sensitive.

### Role / scope minimum

N/A — public identifier.

### Rotation procedure

Only changes if:
- The Apple Developer Program team is renamed (does not change the ID).
- You enroll under a new team (different team ID; would also rotate every
  cert).

### Consequences of loss

NONE. Public information — copy-pastable from the Apple Developer portal at
any time.

---

## `ASC_API_KEY_ID`  (ACTIVE)

**Purpose:** 10-character Key ID for the App Store Connect Team API Key used
by `xcrun notarytool`. Identifies WHICH key to use (the .p8 contents are in
`ASC_API_KEY_P8_BASE64` below).

### How to generate

1. Go to <https://appstoreconnect.apple.com/access/api> (Users and Access →
   Integrations → **Team Keys** tab — NOT Individual Keys).
2. Click the `+` button to create a new key.
3. Name: "MDViewer CI" (or similar; for your reference only).
4. Access: **Developer** role (least privilege per STACK.md sec 3 — Developer
   is the minimum role that can submit to notary).
5. Click "Generate".
6. The key appears in the list with its 10-character Key ID visible.
7. **CRITICAL:** click "Download API Key" immediately. The `.p8` file is
   one-time download — Apple will refuse to re-download it. If you skip this
   step you have to revoke the key and create a new one.
8. The Key ID (10 characters, alphanumeric) is what goes into this secret.
   `pbcopy` it from the App Store Connect page.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `ASC_API_KEY_ID` → paste → Add.

### Role / scope minimum

**Team Key** (NOT Individual Key) with **Developer** role minimum. App Manager
or Admin will also work but violate least-privilege. Notary requires Team Keys
for CI use.

### Rotation procedure

Recommended every 12 months as hygiene:
1. App Store Connect → Users and Access → Integrations → Team Keys → click
   the existing key → "Revoke".
2. Create a new key per "How to generate" above (download the new `.p8`!).
3. Update BOTH `ASC_API_KEY_ID` and `ASC_API_KEY_P8_BASE64` in the same
   sitting. The Issuer ID does not change.

### Consequences of loss

LOW. Repeatable — revoke and recreate any time. But you also rotate
`ASC_API_KEY_P8_BASE64` because the `.p8` is one-time download (lose the .p8
file, you can never get it again for THIS Key ID).

---

## `ASC_API_ISSUER_ID`  (ACTIVE)

**Purpose:** UUID identifying the App Store Connect team that owns the API
key. ONE per team, shared across all keys generated for that team. Required
by `xcrun notarytool` alongside the Key ID.

### How to generate

Find at <https://appstoreconnect.apple.com/access/api> (Users and Access →
Integrations → Team Keys tab). The Issuer ID appears at the top of the page,
above the keys list. It's a UUID like `12345678-1234-1234-1234-123456789012`.

`pbcopy` it from the page.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `ASC_API_ISSUER_ID` → paste → Add.

### Role / scope minimum

N/A — identifier, not a credential. All members of the App Store Connect team
share this Issuer ID.

### Rotation procedure

Never changes. The Issuer ID is per-team-account and persists for the life of
the team.

### Consequences of loss

NONE. Recoverable from the App Store Connect page at any time by anyone with
team-owner access.

---

## `ASC_API_KEY_P8_BASE64`  (ACTIVE)

**Purpose:** the actual private key bytes for the Team API Key. PEM-encoded
EC private key (P-256 curve), wrapped in `-----BEGIN PRIVATE KEY-----` ...
`-----END PRIVATE KEY-----` markers. Stored base64-encoded to survive
GitHub Secrets newline normalization (Pitfall #13).

### How to generate

After downloading `AuthKey_<KEYID>.p8` from App Store Connect (see
`ASC_API_KEY_ID` step 7 above):

```bash
# base64-encode the .p8 to clipboard (Pitfall #13 - direct paste of the .p8
# would corrupt newlines in transit through the GitHub Secrets API):
base64 -i AuthKey_<KEYID>.p8 | pbcopy
```

The clipboard now holds the value to paste into the GitHub Secret.

`Scripts/notarize.sh` decodes this back to a tmpfile via `base64 --decode`,
sanity-checks the first line is `-----BEGIN PRIVATE KEY-----`, and passes the
file path to `xcrun notarytool --key`. The tmpfile is removed on EXIT/INT/TERM
via `trap`.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `ASC_API_KEY_P8_BASE64` → paste → Add.

### Role / scope minimum

The role is set on the Key in App Store Connect (see `ASC_API_KEY_ID` —
Developer minimum). The .p8 itself is just the private key bytes.

**Backup recommendation:** save the original `AuthKey_<KEYID>.p8` file to an
encrypted offline location (1Password, hardware token, encrypted external
drive). Apple will not let you re-download it. Without a backup, losing this
secret means revoking the key and starting over.

### Rotation procedure

Rotate atomically with `ASC_API_KEY_ID` — see that section for the full
flow. Whenever you create a new Team API Key, you must update both secrets.

### Consequences of loss

HIGH severity if no backup, because the .p8 is one-time download from Apple.
RECOVERABLE: revoke the dead key in App Store Connect, generate a new one,
update both `ASC_API_KEY_ID` + `ASC_API_KEY_P8_BASE64` together. NEVER
notarize-blocking longer than a manual ~10-minute rotation.

---

## `SPARKLE_ED_PRIVATE_KEY`  (PHASE 12 — not yet consumed by current workflow)

**Purpose:** EdDSA (Ed25519) private key used by Sparkle's `generate_appcast`
to sign appcast XML entries. Existing v2.2+ installs verify these signatures
against the corresponding PUBLIC key embedded in `Info.plist` as
`SUPublicEDKey` — if the signature fails verification, Sparkle refuses to
install the update.

### How to generate

Once Phase 12 lands and Sparkle is resolved as an SPM dependency, the
`generate_keys` tool ships with the framework. Run it ONCE on the developer
Mac:

```bash
# After Sparkle is resolved in DerivedData, find the binary:
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f -path '*Sparkle*' | head -n1)

# Generate the key pair (interactive: prompts you to add to Keychain).
# This creates a Sparkle-private key entry in the macOS Keychain AND prints
# the public key, which you copy into Info.plist as SUPublicEDKey.
"$SPARKLE_BIN"

# Then export the private key to a file for ingest into the GitHub Secret:
"$SPARKLE_BIN" -x sparkle_private_key.txt

# Copy the contents to clipboard for pasting into GitHub Secrets:
cat sparkle_private_key.txt | pbcopy

# CRITICAL: securely back up sparkle_private_key.txt to TWO offline locations
# before deleting the local copy. See "Consequences of loss" below.
```

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `SPARKLE_ED_PRIVATE_KEY` → paste → Add.

### Role / scope minimum

The corresponding **PUBLIC key** is committed to git as `SUPublicEDKey` in
`Info.plist` (this is correct and intentional; the public key is public by
design). Only the private key needs secret status.

### Rotation procedure

**Severe — see "Consequences of loss".** Rotating the EdDSA key is
practically irreversible because every existing installation has the OLD
public key baked in and will refuse signatures from the new private key.

The only safe rotation paths:
1. Generate a new key pair on the developer Mac.
2. Embed BOTH old and new public keys in `Info.plist` (Sparkle accepts a
   comma-separated list of `SUPublicEDKey` values starting from Sparkle 2.x).
3. Sign appcasts with the NEW private key.
4. Wait at least 18 months (giving slow-updating users time to upgrade).
5. Drop the old public key from `Info.plist` in the next major release.
6. Revoke the old private key from GitHub Secrets ONLY after step 5 ships.

### Consequences of loss

**CATASTROPHIC AND PERMANENT** if not backed up. Per Pitfall #2: lose the
EdDSA private key and you cannot sign updates that existing v2.2+ installs
will accept. Sparkle does not document a fallback to unsigned updates within
any reasonable time window.

**Mitigation (Critical Pre-Release Gate #1 from REQUIREMENTS.md):** the
private key MUST be backed up to at least one offline location BEFORE the
first Sparkle-enabled release ships. Recommended TWO locations; the operator
currently maintains ONE (see "Current backup inventory" below):

1. **Primary backup location:** Encrypted USB drive, operator-controlled,
   stored offline at a physical location under the operator's direct
   custody. Established 2026-04-20 during the Phase 12 Plan 03 Task 3
   key-generation ritual.
2. **Secondary backup location:** _NOT CONFIGURED AT THIS TIME._ The
   operator has consciously elected a single-offline-backup configuration
   for the initial Sparkle ship. See the deviation note under "Provenance"
   below for the risk-acceptance rationale and the roadmap-level criterion
   this configuration satisfies.

Operator must update this section when (if) a second offline backup is
added in the future. NEVER record key bytes here — only LOCATION
descriptions.

### Provenance

- **Key pair generated:** 2026-04-20 by `generate_keys` from the Sparkle
  2.9.1 SPM artefact bundle (`~/Library/Developer/Xcode/DerivedData/.../
  SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`), during the
  Phase 12 Plan 03 Task 3 interactive ritual.
- **Key format:** 44-character base64-encoded 32-byte Ed25519 private
  scalar (Sparkle 2.9.1 default). Note: the Plan 12-03 prose documented an
  expected export size of 88–89 bytes based on older Sparkle-release
  guidance; Sparkle 2.9.1 currently produces a 44-byte base64 representation
  and both `generate_appcast` and `sign_update` accept it natively. Future
  operators should expect 44 bytes, not 88.
- **Public key committed:** `MDViewer/Info.plist` `SUPublicEDKey` at commit
  `b6bdc76` (Plan 12-03 Task 4). Pre-commit diff replaced the Plan 12-01
  placeholder (`PHASE12PLACEHOLDER0000000000000000000000000=`).
- **Private key installed as GitHub Secret:** `SPARKLE_ED_PRIVATE_KEY` at
  `2026-04-20T19:44:33Z` on `mitgor/mdviewer` (verified via
  `gh secret list`).
- **Private key preserved in macOS Keychain:** entry
  `"Private key for signing Sparkle updates"` / service
  `https://sparkle-project.org` on the developer Mac. Required for future
  local `generate_appcast` testing; intentionally retained.
- **Plaintext export deleted:** `~/Desktop/sparkle_private_key.txt` removed
  after GitHub-Secret install and offline-backup completion (2026-04-20).
  Not present in filesystem or Trash.
- **First appcast-signing use:** `v2.2.0-rc.2` dry-run (Phase 12 Plan 03
  Task 7).

#### Single-offline-backup configuration (deviation from Plan 12-03)

Plan 12-03 Task 3 and the plan-level Success Criterion #5 asked for TWO
offline backup locations. The operator has elected a SINGLE-offline-backup
configuration:

- **Configuration chosen:** one offline backup (encrypted USB, operator-
  controlled) + the GitHub Secret = two TOTAL copies of the private key,
  but only ONE of them is offline.
- **Roadmap-level criterion satisfied:** Phase 12 Success Criterion #5 in
  `.planning/milestones/v2.2-ROADMAP.md` requires "at least one documented
  offline location in addition to the GitHub secret" — this single-offline
  configuration MEETS the roadmap-level criterion.
- **Plan-level criterion not fully met:** Plan 12-03's stricter two-offline
  ask is not met. Operator has explicitly accepted the residual risk:
  simultaneous loss of the USB AND the GitHub Secret would be catastrophic
  and permanent (no future Sparkle update could ever reach v2.2+ installs —
  see "Consequences of loss" above).
- **Future mitigation path (recommended, not yet performed):** add a second
  offline backup (1Password Personal vault entry, YubiKey PIV slot, paper
  printout in a physical safe, or similar) before MDViewer has a large
  enough user base that a permanent update-loss event would be materially
  harmful to users. This is a low-effort operation; the generate_keys step
  does not need to re-run — the existing private key can be re-exported
  from the Keychain or copied from the primary backup to a second medium.

Also see `docs/release/sparkle-setup.md` for the full first-time setup
runbook covering `generate_keys` invocation, export, GitHub-Secrets
installation, and the two-offline-backup discipline (including why it
matters and how to add a second backup later).

---

## `HOMEBREW_TAP_PAT`  (PHASE 13 — not yet consumed by current workflow)

**Purpose:** fine-grained GitHub Personal Access Token used by
`macAuley/action-homebrew-bump-cask` to fork `mitgor/homebrew-tap`, edit
`Casks/mdviewer.rb` to bump the version + SHA, and open a PR. Required
because `GITHUB_TOKEN` is scoped to the running repo only and cannot fork
other repos (per ARCHITECTURE.md sec 8).

### How to generate

1. Go to <https://github.com/settings/personal-access-tokens/new>.
2. Token name: `MDViewer homebrew-tap bump`
3. Resource owner: `mitgor`
4. Expiration: 12 months (set a calendar reminder to rotate).
5. Repository access: **Only select repositories** → choose
   `mitgor/homebrew-tap` ONLY. Do NOT grant access to `mitgor/mdviewer` (the
   release workflow already runs there with `GITHUB_TOKEN`).
6. Repository permissions:
   - **Contents:** Read and write (to commit the bumped cask file)
   - **Pull requests:** Read and write (to open the bump PR)
   - All others: No access (least privilege).
7. Click "Generate token". Copy the token (`github_pat_...`) immediately.

### How to install

1. Go to <https://github.com/mitgor/mdviewer/settings/secrets/actions>.
2. New repository secret → `HOMEBREW_TAP_PAT` → paste → Add.

### Role / scope minimum

Fine-grained PAT scoped to `mitgor/homebrew-tap` ONLY, with `Contents: write`
+ `Pull requests: write`. No org-wide access. No access to other repos in
your account. This is the minimum permission set that lets the bump action
work.

### Rotation procedure

Calendar reminder: rotate every 12 months when the PAT expires.

1. Generate a new PAT per "How to generate" above with a fresh 12-month
   expiry.
2. Update `HOMEBREW_TAP_PAT` in GitHub Secrets with the new value.
3. Revoke the old PAT at <https://github.com/settings/personal-access-tokens>.

### Consequences of loss

LOW. Revoke the old PAT (or let it expire naturally), create a new one,
update the secret. No in-flight state lost — at most one missed cask bump
which can be replayed by re-running the failed workflow job after the rotate.

---

## Pre-release checklist

Before cutting the FIRST `v2.2.0` release (or any first-of-milestone release):

- [ ] All ACTIVE secrets are installed and a `v2.2.0-rc.1` dry-run produced a
      stapled DMG on a draft pre-release (Plan 11-02 Task 3, recorded in
      `.planning/phases/11-ci-notarized-release/11-DRY-RUN-LOG.md`).
- [ ] (Phase 12 only) `SPARKLE_ED_PRIVATE_KEY` is backed up offline to TWO
      documented locations and the backup procedure is recorded in this file.
- [ ] (Phase 12 only) `CFBundleVersion` migrated from string to monotonic
      integer (SPK-08). String comparison sort makes "10" < "2" — see
      Pitfall #19.
- [ ] (Phase 12 only) README has a one-time manual-update notice for v2.1
      users (Pitfall #9 — pre-Sparkle installs cannot auto-update).
- [ ] (Phase 13 only) Homebrew cask declares `auto_updates true` (Pitfall #10
      — without it, brew upgrade fights Sparkle).

---

*Last updated: 2026-04-19 (Phase 11 plan 11-02).*
