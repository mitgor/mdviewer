---
phase: 11-ci-notarized-release
plan: 01
subsystem: release-pipeline
tags: [ci, github-actions, codesign, notarization, dmg]
requires:
  - macos-26 GitHub-hosted runner with Xcode 26.2 default
  - GitHub Secrets MAC_CERT_P12_BASE64, MAC_CERT_P12_PASSWORD, KEYCHAIN_PASSWORD,
    APPLE_TEAM_ID, ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64
provides:
  - Tag-triggered build/sign/notarize/staple/verify pipeline producing a stapled DMG
    and dSYM bundle on the runner
affects:
  - .github/workflows/release.yml
  - Scripts/set_version.sh
  - Scripts/import_cert.sh
  - Scripts/build_and_sign.sh
  - Scripts/make_dmg.sh
  - Scripts/notarize.sh
  - Scripts/verify_release.sh
  - ExportOptions.plist
tech-stack:
  added:
    - actions/checkout@v4
    - actions/cache@v4
    - actions/upload-artifact@v4
    - "Apple-Actions/import-codesign-certs@b610f78488812c1e56b20e6df63ec42d833f2d14 (v6.0.0)"
  patterns:
    - "single-job workflow (ARCHITECTURE.md sec 3): keychain handoff and artifact passing
      between jobs costs more than zero parallelism benefit at this scale"
    - "SHA-pinned third-party actions (defends against tag-rewrite supply-chain attacks,
      threat T-11-01)"
    - "dynamic signing-identity discovery via security find-identity -v filtered by team ID
      (defends against same-CN cert ambiguity, threat T-11-02)"
    - ".p8 secret stored as base64, decoded to mktemp tmpfile with trap cleanup
      (Pitfall #13, threat T-11-06)"
key-files:
  created:
    - .github/workflows/release.yml
    - Scripts/set_version.sh
    - Scripts/import_cert.sh
    - Scripts/build_and_sign.sh
    - Scripts/make_dmg.sh
    - Scripts/notarize.sh
    - Scripts/verify_release.sh
    - ExportOptions.plist
  modified: []
decisions:
  - "Pin Apple-Actions/import-codesign-certs at commit
    b610f78488812c1e56b20e6df63ec42d833f2d14 inline rather than leaving the
    REPLACE_WITH_V6_0_0_SHA placeholder for plan 11-02. Rationale: gh CLI was
    authenticated in this session and resolution is deterministic; deferring saves
    one wasted commit in plan 11-02."
  - "ExportOptions.plist at repo root has no signingCertificate key. The xcodebuild
    archive step receives CODE_SIGN_IDENTITY=<SHA-1> on the command line so the
    export step inherits the same identity. Putting the CN string in
    ExportOptions.plist would re-introduce the two-cert ambiguity at export time."
  - "Scripts/import_cert.sh writes signing_id only when GITHUB_OUTPUT is set
    (executor convenience: same script can be sourced manually on a developer Mac)."
  - "actionlint and shellcheck were installed via brew during execution to validate
    the workflow + scripts. Both passed clean (exit 0, no warnings)."
metrics:
  duration: ~5min
  completed: 2026-04-19
---

# Phase 11 Plan 01: CI Signing/Build Pipeline Summary

One-liner: Stand up the build/sign/notarize chain in `.github/workflows/release.yml` with six helper scripts in `Scripts/`, producing a stapled, validated universal DMG plus dSYM bundle on the macos-26 runner.

## What was built

Two atomic commits:

| # | Commit | Subject |
|---|--------|---------|
| 1 | `ac20034` | feat(11-01): add CI signing/build helper scripts and ExportOptions.plist |
| 2 | `6d1aa9c` | feat(11-01): add notarize/verify scripts and release workflow |

Files created (all new, none modified):

| Path | Purpose |
|------|---------|
| `ExportOptions.plist` | developer-id distribution method, teamID V7YK72YLFF, manual signing, no signingCertificate (disambiguated at runtime) |
| `Scripts/set_version.sh` | PlistBuddy-stamps CFBundleShortVersionString and CFBundleVersion in MDViewer/Info.plist (CI-10) |
| `Scripts/import_cert.sh` | `security find-identity -v -p codesigning` filtered by team ID, validates 40-hex SHA-1, writes `signing_id=<sha>` to GITHUB_OUTPUT (CI-04) |
| `Scripts/build_and_sign.sh` | xcodebuild archive + export with `ARCHS="arm64 x86_64"`, `ENABLE_HARDENED_RUNTIME=YES`, `OTHER_CODE_SIGN_FLAGS="--timestamp"`; post-build asserts hardened runtime and universal arch (CI-07) |
| `Scripts/make_dmg.sh` | hdiutil UDZO + DMG codesign with same SHA-1 identity, asserts TeamIdentifier=V7YK72YLFF (CI-08 partial) |
| `Scripts/notarize.sh` | notarytool submit `--key/--key-id/--issuer` (Pitfall #3 - never `--keychain-profile` in CI) `--wait --timeout 25m`; .p8 mktemp+trap (Pitfall #13); fetches `notarytool log` on non-Accepted (Pitfall #4); stapler staple+validate on Accepted (Pitfall #7) (CI-05, CI-06, CI-08) |
| `Scripts/verify_release.sh` | 5 hard gates (universal arch, hardened runtime, app team ID, DMG team ID, stapler validate) plus spctl warning gate |
| `.github/workflows/release.yml` | Single-job tag-triggered workflow on `macos-26` + Xcode 26.2 with timeout 30min; orchestrates all six scripts; uploads notarytool log on `always()` and dSYMs on `success()` (CI-01, CI-02, CI-03, CI-11) |

All scripts: `chmod +x`, `bash -n` clean, `shellcheck` clean.
Workflow: YAML valid, `actionlint` clean.

## Requirements satisfied

| Req | Description | Evidence |
|-----|-------------|----------|
| CI-01 | release.yml on `push: tags: [v*]` | `on: push: tags: ['v*']` line in workflow |
| CI-02 | macos-26 runner + Xcode 26.2 | `runs-on: macos-26` + `xcode-select -s /Applications/Xcode_26.2.app` |
| CI-03 | `Apple-Actions/import-codesign-certs` SHA-pinned | `@b610f78488812c1e56b20e6df63ec42d833f2d14` (v6.0.0) |
| CI-04 | Identity disambiguated by SHA-1 from team ID | `Scripts/import_cert.sh` filters by `($APPLE_TEAM_ID)` and validates 40-hex |
| CI-05 | Notarytool with `--key/--key-id/--issuer` | `Scripts/notarize.sh` line 33-39 |
| CI-06 | notarytool log uploaded on failure | `if: always()` upload-artifact step in workflow |
| CI-07 | Universal + hardened + timestamp | `Scripts/build_and_sign.sh` + post-build `lipo -archs` and `codesign -dvvv` flag check |
| CI-08 | DMG via hdiutil UDZO, signed, stapled | `Scripts/make_dmg.sh` (build/sign) + `Scripts/notarize.sh` (staple) |
| CI-10 | Version stamped from git tag via PlistBuddy | workflow `Stamp version into Info.plist` step calls `set_version.sh` |
| CI-11 | dSYM bundle as workflow artifact | `Upload dSYM bundle` step uploads `build/MDViewer.xcarchive/dSYMs/` retention 90d |

CI-09 (draft GitHub Release), CI-12 (secrets doc), CI-13 (dry-run) are scoped to plan 11-02.

## Deviations from Plan

None. Plan was executed exactly as written, with one judgment call documented under "decisions": the import-codesign-certs SHA was resolved inline (gh CLI was authenticated in-session) rather than left as `REPLACE_WITH_V6_0_0_SHA` for plan 11-02 to resolve. This saves one commit in 11-02 and makes the workflow file feature-complete from this plan forward.

The `softprops/action-gh-release` reference is intentionally NOT yet in the workflow — it lands in plan 11-02 Task 1 along with the draft-release publish step.

## Threat surface scan

No new network endpoints, auth paths, file-access patterns, or schema changes outside the plan's documented threat register. The workflow consumes secrets, writes to the runner filesystem (build/), and uploads artifacts — all anticipated and modeled in plan 11-01's threat register T-11-01..T-11-12.

## Self-Check: PASSED

Created files (all `[ -f ... ]` confirmed):
- `ExportOptions.plist` FOUND
- `Scripts/set_version.sh` FOUND (mode 755)
- `Scripts/import_cert.sh` FOUND (mode 755)
- `Scripts/build_and_sign.sh` FOUND (mode 755)
- `Scripts/make_dmg.sh` FOUND (mode 755)
- `Scripts/notarize.sh` FOUND (mode 755)
- `Scripts/verify_release.sh` FOUND (mode 755)
- `.github/workflows/release.yml` FOUND

Commits exist in git log:
- `ac20034` FOUND
- `6d1aa9c` FOUND
