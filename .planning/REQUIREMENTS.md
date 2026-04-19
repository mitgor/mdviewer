# Requirements: MDViewer v2.2 — Release Quality & Automation

**Defined:** 2026-04-19
**Core Value:** Open a markdown file and see beautifully rendered content instantly

## v2.2 Requirements

### A. v2.1 Quality Closeout (Instruments + Sign-offs)

- [ ] **PERF-04**: Warm launch to first visible content under 150ms for WKWebView path on M-series Mac, captured under Instruments with OSSignposter `open-to-paint` interval; numbers committed to `docs/perf/v2.1-measurements.md`
- [ ] **PERF-05**: Warm launch to first visible content under 100ms for NSTextView path on M-series Mac, captured under Instruments; numbers committed to `docs/perf/v2.1-measurements.md`
- [ ] **PERF-06**: 2nd-file open under 100ms with WKWebView pool active, captured under Instruments; numbers committed to `docs/perf/v2.1-measurements.md`
- [ ] **PERF-07**: STRM-02 buffer-reuse effectiveness validated via Instruments allocations trace; net new String allocations per render documented in `docs/perf/v2.1-measurements.md`
- [ ] **UAT-V21-01**: Phase 07 UAT pending scenario walked through and marked pass/fail in `.planning/phases/07-wkwebview-pool/07-HUMAN-UAT.md`
- [ ] **UAT-V21-02**: Phase 08 UAT pending scenarios (2) walked through and marked pass/fail in `.planning/phases/08-streaming-pipeline/08-HUMAN-UAT.md`
- [ ] **VRF-V21-01..04**: Phase 06–09 VERIFICATION reports updated from `human_needed` to `verified` (or findings filed as new requirements)

### B. CI-Driven Notarized Release Pipeline

- [x] **CI-01**: `.github/workflows/release.yml` exists, triggered on `push: tags: [v*]` (plan 11-01)
- [x] **CI-02**: Workflow runs on `macos-26` runner (arm64) with Xcode 26.2 default toolchain (plan 11-01)
- [x] **CI-03**: Developer ID `.p12` imported into an ephemeral keychain via `Apple-Actions/import-codesign-certs@b610f78488812c1e56b20e6df63ec42d833f2d14` (v6.0.0 SHA-pinned) (plan 11-01)
- [x] **CI-04**: Code-signing identity disambiguated by SHA-1 fingerprint discovered dynamically via `security find-identity -v -p codesigning`, filtered by team ID `V7YK72YLFF` (Scripts/import_cert.sh) (plan 11-01)
- [x] **CI-05**: Notarization uses App Store Connect API key (`.p8` + Key ID + Issuer ID) supplied via `--key/--key-id/--issuer` (Scripts/notarize.sh) (plan 11-01)
- [x] **CI-06**: On notarization failure, `xcrun notarytool log <submissionId>` is fetched and uploaded as a workflow artifact (plan 11-01)
- [x] **CI-07**: Built binary is universal (arm64 + x86_64), signed with hardened runtime, with `--timestamp` (Scripts/build_and_sign.sh) (plan 11-01)
- [x] **CI-08**: DMG built (`hdiutil create -format UDZO`), signed with the same identity, then stapled after notarization (Scripts/make_dmg.sh + Scripts/notarize.sh) (plan 11-01)
- [ ] **CI-09**: Release published as **draft** by default (manual publish gate before appcast points at it)
- [x] **CI-10**: Version derived from the git tag; CI stamps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` via `PlistBuddy` at build time (Scripts/set_version.sh) (plan 11-01)
- [x] **CI-11**: dSYM bundle uploaded as a workflow artifact (90-day retention) (plan 11-01)
- [ ] **CI-12**: All required secrets documented in `docs/release/ci-secrets.md`: `MAC_CERT_P12_BASE64`, `MAC_CERT_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `SPARKLE_ED_PRIVATE_KEY`, `HOMEBREW_TAP_PAT`
- [ ] **CI-13**: First end-to-end CI release dry-run executed against a `v2.2.0-rc.1` pre-release tag before the real `v2.2.0` cut

### C. Sparkle Auto-Update Integration

- [ ] **SPK-01**: Sparkle 2.9.1+ added as an SPM dependency in `MDViewerDeps` (Package.swift) with `.upToNextMajor(from: "2.9.1")`; URL `https://github.com/sparkle-project/Sparkle`
- [ ] **SPK-02**: EdDSA key pair generated via Sparkle `generate_keys`; private key stored as GitHub secret `SPARKLE_ED_PRIVATE_KEY` AND backed up to a documented offline location; public key committed to `Info.plist` as `SUPublicEDKey`
- [ ] **SPK-03**: `Info.plist` `SUFeedURL = https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml`
- [ ] **SPK-04**: `Info.plist` `SUEnableAutomaticChecks = true`; default check interval 86400s (24h)
- [ ] **SPK-05**: "Check for Updates…" menu item wired into the existing AppKit menu via `SPUStandardUpdaterController`
- [ ] **SPK-06**: `generate_appcast` invoked in CI with `--ed-key-file` (key materialized from secret in tmpfs, never to disk on the runner) — eliminates keychain prompt that would otherwise hang the runner
- [ ] **SPK-07**: `phasedRolloutInterval = 43200` (12h) set in appcast for staged rollout
- [ ] **SPK-08**: `CFBundleVersion` migrated from semantic-version string to a monotonically-increasing integer build number BEFORE the first Sparkle-enabled release (Sparkle uses string-sort comparison on `CFBundleVersion`; "2.10" < "2.9" if not numeric)
- [ ] **SPK-09**: `minimumSystemVersion = 13.0` set in appcast (matches `LSMinimumSystemVersion`)
- [ ] **SPK-10**: `verify_bundle.sh` smoke test in CI confirms exactly one `Sparkle.framework` is bundled (guards against the historical SPM double-bundle issue, sparkle-project/Sparkle#1689)
- [ ] **SPK-11**: README updated with a one-time manual-update notice for existing v2.1 installs (they predate Sparkle and will not auto-update)
- [ ] **SPK-12**: Release notes for each version are fetchable as markdown from a stable URL referenced by the appcast item

### D. Homebrew Cask Distribution

- [ ] **BREW-01**: Repo `mitgor/homebrew-tap` exists (must be exactly named `homebrew-tap` for `brew tap mitgor/tap` shorthand)
- [ ] **BREW-02**: `Casks/mdviewer.rb` installs the notarized DMG via the `app:` stanza
- [ ] **BREW-03**: Cask sets `auto_updates true` (mandatory when Sparkle ships in the app — otherwise `brew upgrade` will downgrade the user's installation on top of Sparkle's)
- [ ] **BREW-04**: Cask uses `livecheck strategy: :sparkle` reading the same `appcast.xml` Sparkle reads (single source of truth)
- [ ] **BREW-05**: Cask `zap` stanza covers `~/Library/Preferences/com.mdviewer.app.plist`, saved-state, and caches
- [ ] **BREW-06**: Auto-bump via `macAuley/action-homebrew-bump-cask` triggered after the GitHub Release is published (gated on the draft → publish step)
- [ ] **BREW-07**: Fine-grained PAT `HOMEBREW_TAP_PAT` scoped to the tap repo only (with `contents: write` + `pull_requests: write` permissions); GITHUB_TOKEN cannot fork
- [ ] **BREW-08**: README in `mitgor/homebrew-tap` documents `brew tap mitgor/tap && brew install --cask mdviewer`

## Out of Scope (Decided During v2.2)

| Feature | Reason |
|---------|--------|
| Sparkle delta updates | App is small (~2MB DMG); delta complexity not worth it |
| Sparkle beta channels | No external tester pool |
| Sparkle system profiling | Privacy posture: ship as little as possible |
| Sparkle custom UI | App has no preferences window; standard Sparkle UI is fine |
| Submission to official `homebrew-cask` | Own tap is enough; can submit later if user demand justifies |
| dSYM upload to Sentry / crash service | No crash reporter wired; dSYM-as-artifact is the bridge |
| Slack/Discord/email release notifications | Solo project |
| `xctrace` headless signpost capture for CI perf gating | `xctrace` cannot enable signposts headlessly; perf measurement remains manual on developer Mac |
| Conventional-commits-driven release notes parsing | GitHub-native `generate_release_notes: true` is sufficient for v2.2 |
| New user-facing rendering features (dark mode, search, footnotes, math) | v2.3 candidates |

## Traceability

| Requirement | Phase (proposed) | Status |
|-------------|------------------|--------|
| PERF-04..07 | Phase 10 | Pending |
| UAT-V21-01..02 | Phase 10 | Pending |
| VRF-V21-01..04 | Phase 10 | Pending |
| CI-01..08, CI-10, CI-11 | Phase 11 plan 01 | Complete |
| CI-09, CI-12, CI-13 | Phase 11 plan 02 | Pending |
| SPK-01..12 | Phase 12 | Pending |
| BREW-01..08 | Phase 13 | Pending |

**Coverage:**
- v2.2 requirements: 36 total
- Mapped to phases: 36
- Unmapped: 0

## Critical Pre-Release Gates

Identified by Pitfalls research — must hold before the **first** v2.2 release reaches users:

1. **EdDSA private key backed up offline** (loss = no future Sparkle updates can ever ship to v2.2 installs)
2. **CFBundleVersion migrated to integer scheme** (SPK-08) — irreversible decision once first Sparkle release ships
3. **Release-cycle dry-run completed** on `v2.2.0-rc.1` tag before cutting `v2.2.0`
4. **README migration notice** in place so v2.1 users know to download v2.2 manually once
5. **Homebrew cask `auto_updates true`** verified before tap repo goes live (otherwise `brew upgrade` will fight Sparkle)

---

*Requirements defined: 2026-04-19*
*Research: `.planning/research/v2.2/{STACK,FEATURES,ARCHITECTURE,PITFALLS}.md`*
