---
phase: 12-sparkle-auto-update-integration
plan: 02
subsystem: infra
tags: [sparkle, ci, github-actions, eddsa, appcast, notarization, bash, python]

# Dependency graph
requires:
  - phase: 11-ci-notarized-release
    provides: "release.yml skeleton (build/sign/notarize/staple/draft-release); Scripts/*.sh Phase 11 scripts (unchanged); docs/release/ci-secrets.md secret inventory incl. SPARKLE_ED_PRIVATE_KEY slot"
provides:
  - "Scripts/verify_bundle.sh — pre-notarize bundle-layout smoke test (8 invariants; SPK-10 defence)"
  - "Scripts/generate_appcast.sh — CI wrapper around Sparkle's generate_appcast CLI with stdin key pattern + Python 3 XML post-processor"
  - ".github/workflows/release.yml — extended with two new steps and appcast attached to draft release"
  - "EdDSA-signed build/appcast.xml asset per tag push (phasedRolloutInterval=43200, minimumSystemVersion=13.0.0, releaseNotesLink)"
affects: [12-03, 13-homebrew-cask]

# Tech tracking
tech-stack:
  added:
    - "Sparkle 2.x generate_appcast CLI invocation (discovered dynamically via find under DerivedData)"
    - "Python 3 stdlib xml.etree.ElementTree — namespace-aware XML post-processing (upsert pattern)"
  patterns:
    - "CI secret-to-subprocess streaming via stdin (printf | tool --ed-key-file -) — never touches runner disk"
    - "Binary-path discovery via find under DerivedData (hash-agnostic; fail-loud if absent)"
    - "Single-DMG staging for appcast generation (one <item> per tag; GitHub Releases is the historical record)"
    - "PASS/::error:: line annotations matching Phase 11 Scripts/*.sh style"

key-files:
  created:
    - "Scripts/verify_bundle.sh"
    - "Scripts/generate_appcast.sh"
  modified:
    - ".github/workflows/release.yml"

key-decisions:
  - "Single-DMG staging (not full-history regeneration, not append-to-previous)"
  - "Python 3 stdlib xml.etree for post-processing (not xmlstarlet; stdlib preinstalled on macos-26)"
  - "Stdin key materialisation (not tempfile+trap) — tempfile pattern documented as fallback comment only"
  - "Post-processor UPSERT (find existing element, set text; else create) — idempotent against future generate_appcast flag additions"
  - "verify_bundle.sh checks 8 invariants (framework count, path, XPCs, team ID, hardened runtime, Info.plist keys, integer CFBundleVersion) — beyond SPK-10's literal one-framework check"
  - "--maximum-deltas 0 passed explicitly (MDViewer does not use Sparkle delta updates per milestone scope)"
  - "Obsolete 'Sparkle appcast generation is Phase 12, NOT this phase' comment removed from release.yml tail"

patterns-established:
  - "Pattern 1 (CI key streaming): `printf '%s' \"$SECRET\" | tool --key-file -` avoids Pitfall B (newline corruption) and keeps key out of ps / $RUNNER_TEMP / job logs"
  - "Pattern 2 (binary discovery): `find ~/Library/Developer/Xcode/DerivedData -path '*SourcePackages/artifacts/<pkg>/<Pkg>/bin/*' -name <binary>` — per-build hash-agnostic discovery"
  - "Pattern 3 (inline Python heredoc for XML post-processing): `python3 - path version <<'PY' ... PY` with ET.register_namespace + upsert — keeps post-processing in one file, no .py sidecar"
  - "Pattern 4 (workflow step insertion): new steps land between existing ones with explanatory comment blocks matching Phase 11 annotation density"

requirements-completed: [SPK-06, SPK-07, SPK-09, SPK-10, SPK-12]

# Metrics
duration: 3min
completed: 2026-04-20
---

# Phase 12 Plan 02: CI Appcast Generation + Bundle Verification Summary

**Release workflow now produces an EdDSA-signed appcast.xml alongside the notarized DMG on every tag push, with a pre-notarize bundle-layout smoke test that fails fast on the SPM double-Sparkle-framework regression, team-ID mismatches on XPC services, and non-integer CFBundleVersion.**

## Performance

- **Duration:** ~3 min (plan executor only; ~190s wall-clock)
- **Started:** 2026-04-20T13:22:40Z
- **Completed:** 2026-04-20T13:25:50Z
- **Tasks:** 3 / 3
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments

- `Scripts/verify_bundle.sh` — 8 invariants enforced (SPK-10 + 7 defence-in-depth checks matching Research §Runtime State Verification)
- `Scripts/generate_appcast.sh` — EdDSA-signed appcast generation with stdin key pattern, Python-3 post-processor injecting MDViewer's rollout metadata (SPK-06, SPK-07, SPK-09 appcast side, SPK-12)
- `.github/workflows/release.yml` — extended from 15 steps to 17 steps (delta=+2); `build/appcast.xml` attached to softprops/action-gh-release draft alongside the DMG
- Obsolete 'Sparkle appcast generation is Phase 12, NOT this phase' comment removed

## Task Commits

Each task was committed atomically with `--no-verify` (parallel executor in worktree):

1. **Task 1: Write Scripts/verify_bundle.sh** — `f294bd1` (feat)
2. **Task 2: Write Scripts/generate_appcast.sh** — `1e66fa3` (feat)
3. **Task 3: Insert verify_bundle + generate_appcast steps into release.yml** — `186267e` (feat)

Final metadata commit (SUMMARY.md) — added after self-check below.

## Files Created/Modified

- `Scripts/verify_bundle.sh` (81 lines, executable) — pre-notarize bundle-layout smoke test
- `Scripts/generate_appcast.sh` (132 lines, executable) — appcast generation + EdDSA signing + Python post-processor
- `.github/workflows/release.yml` (+17 / -1 lines) — two new steps + appcast in gh-release files list

## Workflow Step Diff

Before (Phase 11): 15 `- name:` entries. After (post Plan 12-02): 17 `- name:` entries. Delta = +2. New steps:

- Step 11 (was 10+half): `Verify bundle layout (SPK-10)` — between `Build + sign DMG` and `Notarize + staple`
- Step 14 (was 12+half): `Generate EdDSA-signed appcast (SPK-06, SPK-07, SPK-09, SPK-12)` — between `Verify release artifacts` and `Upload notarytool log`

Step ordering verified by awk line-number check (Task 3 `<verify automated>`): `Verify bundle layout < Notarize + staple` AND `Verify release artifacts < Generate EdDSA-signed appcast < Upload notarytool log`.

## Phase 11 Script Isolation Confirmation

`git diff --name-only 446c51e..HEAD` returns exactly:

```
.github/workflows/release.yml
Scripts/generate_appcast.sh
Scripts/verify_bundle.sh
```

All six Phase 11 scripts (`build_and_sign.sh`, `import_cert.sh`, `make_dmg.sh`, `notarize.sh`, `set_version.sh`, `verify_release.sh`) — verified UNTOUCHED individually via `git diff --quiet`. Zero regression surface into Phase 11's pipeline.

## Decisions Made

All seven locked decisions from the plan's `Locked decisions (apply verbatim)` block were followed without deviation:

- verify_bundle.sh lives at `Scripts/verify_bundle.sh`, takes `<app-path> <team-id>` — matches `build_and_sign.sh` two-arg convention.
- generate_appcast.sh lives at `Scripts/generate_appcast.sh`, takes `<version> <dmg-path>`.
- Appcast output path: `build/appcast.xml`.
- Post-processor is inline Python 3 heredoc (no separate `.py` file).
- Channel `<link>` → `https://github.com/mitgor/mdviewer`; per-item `<sparkle:releaseNotesLink>` → tag page.
- Single-DMG staging.
- Python 3 (stdlib `xml.etree.ElementTree`), not xmlstarlet, not sed.
- Stdin key materialisation; tempfile-with-trap retained as documentation-only fallback.

## Deviations from Plan

**None** — plan executed exactly as written. All three tasks' script bodies were reproduced from the plan's `<action>` blocks verbatim, and all three automated `<verify>` predicates passed on first execution (zero fix iterations).

No Rule 1 (bug), Rule 2 (missing critical), Rule 3 (blocking), or Rule 4 (architectural) triggers fired. No auth gates. No checkpoints (plan was fully autonomous).

## Issues Encountered

None. The read-before-edit hook surfaced reminders on three sequential edits to `.github/workflows/release.yml` within the same session — all three edits had applied successfully despite the reminder; this was noise, not a blocker. Read was already in-session before the first edit.

## Assumptions (A1–A6 from 12-RESEARCH.md)

- **A1 (Sparkle 2.9.1 under Xcode 26.2 on macos-26):** Not exercised by this plan — deferred to Plan 3's rc.2 dry-run.
- **A2 (releaseNotesLink rendering):** Not exercised — deferred to first real release smoke test.
- **A3 (CFBundleVersion=220 monotonic scheme):** Not exercised — Plan 3 owns the Info.plist migration; Task 1 only enforces the invariant.
- **A4 (xml.etree preserves `sparkle:edSignature` bytes on round-trip):** Code path ready and defended by step-6 sanity grep (`grep -q 'sparkle:edSignature'`). Not empirically exercised until rc.2 dry-run. Residual risk remains LOW per Research §Assumptions.
- **A5 (`/releases/latest/download/appcast.xml` URL resolution):** Not exercised — deferred to first published (non-draft, non-pre-release) release.
- **A6 (`printf '%s'` survives GitHub's secret-redaction to subprocess stdin):** Code path ready. Confirmed no `set -x` / `echo` of secret in script or workflow step. Residual risk LOW.

All six assumptions remain untested at plan-end; none are silent-corruption risks. Plan 3's rc.2 dry-run is the forward integration test.

## Dry-Run Deferral

Appcast verification against a real tag is deferred to Plan 3's `v2.2.0-rc.2` dry-run (per Phase 11 CI-13 + Phase 12 Plan 3 scope). This plan provides the CI machinery; it does not tag a release itself. Do NOT push a `v*` tag without first completing Plan 3 (CFBundleVersion migration + real SUPublicEDKey installation + offline key backup).

## User Setup Required

None for this plan. Plan 3 owns the pre-release operator gates (key generation, offline backup, Info.plist public-key replacement, README notice for v2.1 users).

## Next Phase Readiness

- Plan 3 is unblocked — it can edit `Scripts/set_version.sh` (CFBundleVersion integer scheme), `MDViewer/Info.plist` (public key replacement), and documentation without touching any file this plan owns.
- Plan 12-01 (app-side Sparkle wiring) sits in the same wave and runs in parallel; files do not overlap.
- Dry-run blocker for first real v2.2.0 tag: Plan 3 must land before any tag push.

## Self-Check

File existence:

- FOUND: Scripts/verify_bundle.sh
- FOUND: Scripts/generate_appcast.sh
- FOUND: .github/workflows/release.yml (modified)

Commit hash presence (`git log --oneline --all | grep -q <hash>`):

- FOUND: f294bd1 (Task 1)
- FOUND: 1e66fa3 (Task 2)
- FOUND: 186267e (Task 3)

## Self-Check: PASSED

---
*Phase: 12-sparkle-auto-update-integration*
*Plan: 02*
*Completed: 2026-04-20*
