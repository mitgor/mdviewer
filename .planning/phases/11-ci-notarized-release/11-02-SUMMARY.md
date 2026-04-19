---
phase: 11-ci-notarized-release
plan: 02
subsystem: release-pipeline
tags: [ci, github-actions, github-release, secrets, dry-run]
status: paused-at-checkpoint
requires:
  - .github/workflows/release.yml from plan 11-01
  - All seven ACTIVE GitHub Secrets installed in mitgor/mdviewer (see
    docs/release/ci-secrets.md)
provides:
  - Workflow now creates a draft GitHub Release on tag push with the stapled
    DMG attached (CI-09)
  - Operator runbook for every CI secret with rotation and loss-impact
    procedures (CI-12)
affects:
  - .github/workflows/release.yml (extended)
  - docs/release/ci-secrets.md (created)
tech-stack:
  added:
    - "softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65 (v2 = release 2.6.2)"
  patterns:
    - "draft-by-default GitHub Release - manual publish gate before Phase 12
      Sparkle appcast points at it"
    - "prerelease auto-detection via contains(tag, '-') so v*-rc.* tags do not
      promote to stable"
    - "operator-grade documentation: every secret has 5 sub-sections (purpose,
      generate, install, role minimum, rotation, loss) for the once-per-18-month
      rotation case"
key-files:
  created:
    - docs/release/ci-secrets.md
  modified:
    - .github/workflows/release.yml
decisions:
  - "softprops/action-gh-release v2 SHA-pinned at 3bb12739c298aeb8a4eeaf626c5b8d85266b0e65
    (= release 2.6.2 at execution time) per T-11-13."
  - "ci-secrets.md documents PHASE 12 (SPARKLE_ED_PRIVATE_KEY) and PHASE 13
    (HOMEBREW_TAP_PAT) secrets even though they are not yet consumed by the
    workflow. Rationale: the CI-12 requirement explicitly enumerates all 9
    secrets, and operators benefit from a single source of truth across the
    upcoming phases."
  - "Sparkle private-key offline-backup section intentionally has placeholder
    'DOCUMENT HERE WHEN BACKUP IS CREATED' lines for the operator to fill in
    at Phase 12 launch (Critical Pre-Release Gate #1 from REQUIREMENTS.md).
    The doc instructs to record the LOCATION not the key bytes (T-11-16)."
metrics:
  duration: ~3min for tasks 1+2 (Task 3 dry-run is deferred to user)
  completed: ""
  paused_at: 2026-04-19 (Task 3 human-verify checkpoint)
---

# Phase 11 Plan 02: Draft Release + Secrets Docs + Dry-Run Summary (PARTIAL — paused at checkpoint)

One-liner: Extended `.github/workflows/release.yml` with the SHA-pinned `softprops/action-gh-release` draft-publish step (CI-09) and shipped the `docs/release/ci-secrets.md` operator runbook covering all 9 release-pipeline secrets (CI-12). **Task 3 (v2.2.0-rc.1 dry-run, CI-13) is a human-verify checkpoint deferred to the user — see "Checkpoint Status" below.**

## What was built

Two atomic commits for the autonomous tasks:

| # | Commit | Subject |
|---|--------|---------|
| 1 | `96feb33` | feat(11-02): add draft GitHub Release publish step (CI-09) |
| 2 | `132d693` | docs(11-02): add ci-secrets.md operator runbook (CI-12) |

### Task 1 (commit `96feb33`) — release.yml publish step

Appended to `.github/workflows/release.yml`:

```yaml
- name: Create draft GitHub Release (CI-09)
  uses: softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65
  with:
    tag_name: ${{ steps.version.outputs.tag }}
    name: MDViewer ${{ steps.version.outputs.version }}
    draft: true
    prerelease: ${{ contains(steps.version.outputs.tag, '-') }}
    generate_release_notes: true
    files: |
      build/MDViewer-${{ steps.version.outputs.version }}.dmg
    fail_on_unmatched_files: true
```

actionlint: clean. YAML: valid.

### Task 2 (commit `132d693`) — docs/release/ci-secrets.md

529-line operator runbook with one major section per secret (9 sections), each containing: Purpose, How to generate, How to install, Role/scope minimum, Rotation procedure, Consequences of loss. Closes with a Pre-release checklist mirroring REQUIREMENTS.md "Critical Pre-Release Gates 1–5".

Verified against acceptance criteria: all 9 secret names present (`MAC_CERT_P12_BASE64`, `MAC_CERT_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `SPARKLE_ED_PRIVATE_KEY`, `HOMEBREW_TAP_PAT`); team ID `V7YK72YLFF`; "Team Key" + "Developer role" minimum for ASC; "base64-encode" instruction for the .p8 (Pitfall #13); Sparkle offline-backup gate; Pre-release checklist.

## Checkpoint Status: Task 3 (CI-13) BLOCKED ON HUMAN

**Type:** `checkpoint:human-verify`
**What's needed:** End-to-end CI release dry-run against `v2.2.0-rc.1`.

The executor cannot perform Task 3 because:
1. It requires installing seven GitHub Secrets in `mitgor/mdviewer` repo settings (cert .p12, ASC API key, etc.).
2. It requires pushing a tag to trigger the workflow on GitHub-hosted infrastructure.
3. It requires interacting with the real Apple notary service.
4. It requires downloading and locally verifying the DMG on the user's Mac.

Once the user completes the dry-run and produces `.planning/phases/11-ci-notarized-release/11-DRY-RUN-LOG.md`, this summary should be flipped from `status: paused-at-checkpoint` to `status: complete`, and CI-13 marked done in REQUIREMENTS.md.

**Step-by-step instructions** are in `11-02-PLAN.md` Task 3. Quick punch list:

1. `gh secret list --repo mitgor/mdviewer` — confirm the 7 ACTIVE secrets from `docs/release/ci-secrets.md` are installed. Generate any missing ones per the runbook.
2. `git tag v2.2.0-rc.1 && git push origin v2.2.0-rc.1`
3. `gh run watch` — monitor; expect <30 min wall-clock.
4. `gh release view v2.2.0-rc.1 --repo mitgor/mdviewer` — confirm `draft: true`, `prerelease: true`, DMG attached.
5. `gh release download v2.2.0-rc.1 --repo mitgor/mdviewer --pattern "*.dmg"` — pull the asset.
6. Verify locally: `lipo -info` (universal), `codesign -dvvv` (hardened + team), `xcrun stapler validate` (stapled), `spctl -a -t open` (Gatekeeper accepts).
7. Fill in `.planning/phases/11-ci-notarized-release/11-DRY-RUN-LOG.md` with workflow run URL, durations, asset SHA-256, observation table.
8. Cleanup: `gh release delete v2.2.0-rc.1 --repo mitgor/mdviewer --yes && git push --delete origin v2.2.0-rc.1 && git tag -d v2.2.0-rc.1` (or keep the prerelease for Phase 12 smoke testing — your call).
9. Mark CI-13 complete in REQUIREMENTS.md and flip this summary to `status: complete`.

## Deviations from Plan

None. Plan was executed exactly as written. The Apple-Actions SHA placeholder that plan 11-02 Task 1 was supposed to resolve had already been resolved in plan 11-01 (executor noted this as a decision). Task 3's checkpoint is the planned execution model — not a deviation.

## Threat surface scan

No new network endpoints, auth paths, file-access patterns, or schema changes outside the plan's documented threat register (T-11-13..T-11-19). Notable: the docs file is intentionally public (T-11-15: names and procedures are not secret; values are in GitHub Secrets which are encrypted at rest and never logged).

## Self-Check: PASSED

Created/modified files:
- `docs/release/ci-secrets.md` FOUND
- `.github/workflows/release.yml` FOUND (modified — softprops/action-gh-release step appended)

Commits exist in git log:
- `96feb33` FOUND
- `132d693` FOUND

Acceptance criteria verifications all pass (see Task 1/Task 2 sections above).

Outstanding (deferred to human):
- `.planning/phases/11-ci-notarized-release/11-DRY-RUN-LOG.md` — to be created by the user after the dry-run completes.
