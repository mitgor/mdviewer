---
gsd_state_version: 1.0
milestone: v2.2
milestone_name: Release Quality & Automation
status: ready_to_plan
stopped_at: Plan 11-02 Task 3 human checkpoint (v2.2.0-rc.1 dry-run)
last_updated: "2026-04-20T12:17:01.688Z"
last_activity: 2026-04-20 -- Phase 10 execution started
progress:
  total_phases: 4
  completed_phases: 2
  total_plans: 3
  completed_plans: 2
  percent: 50
---

# Project State

## Project Reference

See: `.planning/PROJECT.md` (updated 2026-04-19 — v2.2 opened)

**Core value:** Open a markdown file and see beautifully rendered content instantly
**Current focus:** Phase 10 — v21-quality-closeout

## Current Position

Phase: 11
Plan: Not started
Status: Ready to plan
Last activity: 2026-04-20

## Accumulated Context

### Decisions

Decisions are logged in `PROJECT.md` Key Decisions table. Per-milestone summaries live in `milestones/vX.Y-ROADMAP.md`.

Phase 11 plan 11-01 decisions:

- Pinned `Apple-Actions/import-codesign-certs` at commit `b610f78488812c1e56b20e6df63ec42d833f2d14` (v6.0.0) inline rather than leaving placeholder for plan 11-02 (gh CLI was authenticated; saves a wasted commit downstream).
- `ExportOptions.plist` at repo root has no `signingCertificate` key — identity is passed via `CODE_SIGN_IDENTITY=<SHA-1>` to `xcodebuild archive` so export inherits it. Putting the CN in the plist would re-introduce the two-cert ambiguity at export time.

Phase 11 plan 11-02 decisions:

- Pinned `softprops/action-gh-release` at commit `3bb12739c298aeb8a4eeaf626c5b8d85266b0e65` (v2 = release 2.6.2 at execution time).
- `prerelease` flag derived from `contains(steps.version.outputs.tag, '-')` so `v*-rc.*` tags auto-mark as pre-release; `v*.*.*` proper releases do not.
- `docs/release/ci-secrets.md` documents all 9 secrets including PHASE 12 (`SPARKLE_ED_PRIVATE_KEY`) and PHASE 13 (`HOMEBREW_TAP_PAT`) ones, marked clearly as "not yet consumed by current workflow" — operator-grade single source of truth.

### Pending Todos

- **Phase 11 dry-run (CI-13)**: Push `v2.2.0-rc.1` tag to `mitgor/mdviewer`, watch the workflow run, verify the produced DMG locally, fill in `.planning/phases/11-ci-notarized-release/11-DRY-RUN-LOG.md`. Step-by-step in plan 11-02 Task 3.
- **Phase 11 secret install**: Verify `gh secret list --repo mitgor/mdviewer` shows all seven ACTIVE secrets from `docs/release/ci-secrets.md`. Generate any that are missing per the runbook.

### Blockers/Concerns

- **Sub-100ms warm launch target** from v2.1 is instrumented but not yet measured on the shipped build. Last recorded measurement was 184.50ms on M4 Max pre-v2.1.
- v2.1 closed with 6 deferred human-verification items (see below) that should be walked through when convenient.
- *(resolved 2026-04-18)* v2.0 phase directories archived to `milestones/v2.0-*.md` and removed from working tree; git history retains the full per-phase artifacts.

## Deferred Items

Items acknowledged and deferred at v2.1 milestone close on 2026-04-18:

| Category | Item | Status |
|----------|------|--------|
| uat_gaps | Phase 07 — 07-HUMAN-UAT.md | partial (1 pending scenario) |
| uat_gaps | Phase 08 — 08-HUMAN-UAT.md | partial (2 pending scenarios) |
| verification_gaps | Phase 06 — 06-VERIFICATION.md | human_needed |
| verification_gaps | Phase 07 — 07-VERIFICATION.md | human_needed |
| verification_gaps | Phase 08 — 08-VERIFICATION.md | human_needed |
| verification_gaps | Phase 09 — 09-VERIFICATION.md | human_needed |

All six items are human-sign-off checkpoints; the code-level work they gate is complete and shipped in the public v2.1 release. See `milestones/v2.1-REQUIREMENTS.md` for the specific measurements/visuals they track.

## Session Continuity

Last session: 2026-04-19 (Phase 11 execution)
Stopped at: Plan 11-02 Task 3 human checkpoint (v2.2.0-rc.1 dry-run)
Resume file: `.planning/phases/11-ci-notarized-release/11-02-PLAN.md` Task 3
