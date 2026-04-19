# Roadmap: MDViewer

## Current Milestone — v2.2 Release Quality & Automation

**Goal:** Close v2.1 quality debts (Instruments measurement, UAT/verification sign-off) and make future releases cheap by moving sign/notarize/publish into CI, adding Sparkle auto-update, and publishing via Homebrew.

## Phases

- [ ] **Phase 10: v2.1 Quality Closeout** — Instruments measurement of v2.1 perf targets and human sign-off on deferred UAT/VERIFICATION items
- [ ] **Phase 11: CI Notarized Release Pipeline** — `release.yml` GitHub Actions workflow that builds, signs, notarizes, and publishes a draft release on tag push
- [ ] **Phase 12: Sparkle Auto-Update Integration** — Sparkle 2.x SPM dependency, EdDSA-signed appcast, "Check for Updates…" menu, and CI-driven appcast generation
- [ ] **Phase 13: Homebrew Cask Distribution** — `mitgor/homebrew-tap` with `mdviewer.rb` cask, auto-bumped from the release workflow

## Phase Details

### Phase 10: v2.1 Quality Closeout

**Goal**: All v2.1 perf targets are measured under Instruments with numbers committed to the repo, and every deferred UAT/VERIFICATION item from v2.1 is signed off (or escalated as a new requirement).
**Depends on**: Nothing (operates on shipped v2.1 artifacts; can run in parallel with Phases 11–13).
**Requirements**: PERF-04, PERF-05, PERF-06, PERF-07, UAT-V21-01, UAT-V21-02, VRF-V21-01, VRF-V21-02, VRF-V21-03, VRF-V21-04
**Success Criteria** (what must be TRUE):
  1. `docs/perf/v2.1-measurements.md` exists and contains four numbered measurement entries (WKWebView warm launch, NSTextView warm launch, 2nd-file pool open, STRM-02 buffer-reuse allocations) each with the captured Instruments interval/trace name and the M-series Mac model used
  2. WKWebView path warm launch ≤150ms and NSTextView path warm launch ≤100ms are observed in the recorded `OSSignposter(open-to-paint)` interval, OR a regression is filed as a new requirement
  3. Phase 07 and Phase 08 `*-HUMAN-UAT.md` files have every pending scenario marked PASS or FAIL with a dated note
  4. Phase 06–09 `*-VERIFICATION.md` files no longer contain `human_needed`; each is `verified` or has produced new requirements that supersede it
  5. Any new requirement filed during this phase (e.g. perf miss, UAT failure) is recorded in `.planning/REQUIREMENTS.md` for triage in v2.3+
**Plans**: 1 (estimated)

### Phase 11: CI Notarized Release Pipeline

**Goal**: Pushing a `v*` tag to `mitgor/mdviewer` produces a notarized, stapled, signed universal DMG attached to a draft GitHub Release, with no developer-Mac involvement.
**Depends on**: Nothing release-blocking (Phase 10 can run in parallel; Phases 12 and 13 depend on this one).
**Requirements**: CI-01, CI-02, CI-03, CI-04, CI-05, CI-06, CI-07, CI-08, CI-09, CI-10, CI-11, CI-12, CI-13
**Success Criteria** (what must be TRUE):
  1. `.github/workflows/release.yml` runs end-to-end on a `macos-26` arm64 runner with Xcode 26.2, triggered by `push: tags: [v*]`, completing in <30 minutes
  2. The published DMG is universal (`lipo -info` shows `arm64 x86_64`), hardened-runtime + secure-timestamp signed with the Developer ID identity disambiguated by SHA-1 (team `V7YK72YLFF`), and `xcrun stapler validate` passes
  3. On notarization failure the workflow uploads `xcrun notarytool log <submissionId>` output as a workflow artifact, and on success a dSYM bundle is uploaded as a workflow artifact
  4. The GitHub Release is created as a **draft** by default (no appcast pointer flips automatically); `Info.plist` `CFBundleShortVersionString` and `CFBundleVersion` are stamped at build time from the git tag via `PlistBuddy`
  5. `docs/release/ci-secrets.md` documents every required secret (`MAC_CERT_P12_BASE64`, `MAC_CERT_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `SPARKLE_ED_PRIVATE_KEY`, `HOMEBREW_TAP_PAT`) with the team API key role minimum and rotation procedure
  6. **Pre-release gate:** A first end-to-end CI dry-run has been executed against a `v2.2.0-rc.1` pre-release tag and produced a notarized stapled DMG before any real `v2.2.0` cut
**Plans**: 2 (estimated)

### Phase 12: Sparkle Auto-Update Integration

**Goal**: Shipped v2.2 builds check `https://github.com/mitgor/mdviewer/releases/latest/download/appcast.xml` daily, verify EdDSA signatures, and install updates via the standard Sparkle UI; CI generates and signs the appcast on every release.
**Depends on**: Phase 11 (the appcast is generated and signed inside the release workflow; key materialization and `verify_bundle.sh` smoke test live in CI).
**Requirements**: SPK-01, SPK-02, SPK-03, SPK-04, SPK-05, SPK-06, SPK-07, SPK-08, SPK-09, SPK-10, SPK-11, SPK-12
**Success Criteria** (what must be TRUE):
  1. Sparkle 2.9.1+ is resolved as an SPM dependency (`Package.swift` + `project.yml`); the shipped `MDViewer.app` contains exactly one `Sparkle.framework` (verified in CI by `verify_bundle.sh`); `Info.plist` declares `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks=true`, `SUScheduledCheckInterval=86400`, and `minimumSystemVersion=13.0` (in the appcast)
  2. A "Check for Updates…" menu item under the app menu is wired to `SPUStandardUpdaterController.checkForUpdates(_:)` and successfully presents Sparkle's standard sheet against a live appcast
  3. CI's `generate_appcast` step materializes the EdDSA private key from `SPARKLE_ED_PRIVATE_KEY` into tmpfs (never to runner disk), produces `appcast.xml` with `phasedRolloutInterval=43200` and a per-version release-notes URL, and uploads it as a release asset
  4. **Pre-release gate (irreversible):** `CFBundleVersion` has been migrated from the current "1.0" string to a monotonically-increasing integer scheme BEFORE this milestone's first Sparkle-enabled release ships (Sparkle compares `CFBundleVersion` lexicographically — string-version means future updates can be missed)
  5. **Pre-release gate (key durability):** The EdDSA private key has been backed up to at least one documented offline location in addition to the GitHub secret, and the backup procedure is captured in `docs/release/ci-secrets.md` (loss = no future Sparkle updates can ever reach v2.2 installs)
  6. **Pre-release gate (migration):** README has a one-time manual-update notice for v2.1 users explaining that v2.1 predates Sparkle and they must download v2.2 manually once
**Plans**: 3 (estimated)

### Phase 13: Homebrew Cask Distribution

**Goal**: A user can run `brew tap mitgor/tap && brew install --cask mdviewer` and receive the same notarized DMG the GitHub Release ships, with `brew upgrade` deferring to Sparkle for future updates.
**Depends on**: Phase 12 (cask uses `livecheck strategy: :sparkle` reading the same `appcast.xml`; cannot ship until that appcast is live).
**Requirements**: BREW-01, BREW-02, BREW-03, BREW-04, BREW-05, BREW-06, BREW-07, BREW-08
**Success Criteria** (what must be TRUE):
  1. Repository `mitgor/homebrew-tap` exists with `Casks/mdviewer.rb` installing `MDViewer.app` from the GitHub release DMG via the `app` stanza, `depends_on macos: ">= :ventura"`, and a `zap trash:` covering `~/Library/Preferences/com.mdviewer.app.plist`, saved-state, and caches
  2. `brew install --cask mitgor/tap/mdviewer` from a clean Mac launches the app with no Gatekeeper warning, and `brew uninstall --zap --cask mdviewer` removes every artifact in the `zap` list
  3. The cask uses `livecheck strategy: :sparkle` pointed at the same `appcast.xml` Sparkle reads (single source of truth for "what version is current")
  4. The release workflow's `macAuley/action-homebrew-bump-cask` step runs after the GitHub Release publish gate (not on draft) using a fine-grained `HOMEBREW_TAP_PAT` scoped to `mitgor/homebrew-tap` only with `contents: write` + `pull_requests: write`; a successful bump PR has been opened against the tap by the dry-run release
  5. `mitgor/homebrew-tap/README.md` documents the install one-liner `brew tap mitgor/tap && brew install --cask mdviewer`
  6. **Pre-release gate:** Cask declares `auto_updates true` and this is verified before the tap repo is announced — without it `brew upgrade` will fight Sparkle and silently downgrade users
**Plans**: 2 (estimated)

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 10. v2.1 Quality Closeout | 0/1 | Not started | - |
| 11. CI Notarized Release Pipeline | 0/2 | Not started | - |
| 12. Sparkle Auto-Update Integration | 0/3 | Not started | - |
| 13. Homebrew Cask Distribution | 0/2 | Not started | - |

---

## Shipped Milestones

- **v2.1 Deep Optimization** — Phases 06–09, shipped 2026-04-18. See [milestones/v2.1-ROADMAP.md](milestones/v2.1-ROADMAP.md).
- **v2.0 Speed & Memory** — Phases 01–05, shipped 2026-04-16. See [milestones/v2.0-ROADMAP.md](milestones/v2.0-ROADMAP.md).

See [MILESTONES.md](MILESTONES.md) for the index.

---

<details>
<summary>v2.0 Speed & Memory (Phases 1–5) — shipped 2026-04-16</summary>

- [x] **Phase 1: Correctness & Measurement Baseline** — Fix WKWebView retain cycle and add os_signpost instrumentation so all subsequent measurements are valid
- [x] **Phase 2: Large File Memory & Progressive Rendering** — Memory-mapped file reads and true N-chunk progressive rendering for 10MB+ files
- [x] **Phase 3: Launch Speed** — WKWebView pre-warm and sub-100ms warm launch target
- [x] **Phase 4: Mermaid Script Loading** — Replace 3MB evaluateJavaScript bridge call with script-src loading
- [x] **Phase 5: Window Management** — Persistent window positions and proper multi-window cascading

</details>
