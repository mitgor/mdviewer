---
phase: 10-v21-quality-closeout
plan: 01
subsystem: quality-closeout
tags: [perf, instruments, uat, verification, signoff, v2.1-debt]
status: complete

requires:
  - Phases 06–09 shipped with five acknowledged-deferred items (4 perf targets unmeasured, 3 HUMAN-UAT scenarios pending, 4 VERIFICATION.md reports at `status: human_needed`)
  - Developer Mac with Instruments GUI (xctrace cannot enable signposts headlessly per PITFALLS #16)
provides:
  - v2.1 Instruments measurement record with 4 entries (PERF-04..07) on M4 Max / macOS 26.4
  - All Phase 06–09 VERIFICATION.md files flipped from `human_needed` → `verified`
  - Phase 07 + Phase 08 HUMAN-UAT.md files signed off with PASS/FAIL per scenario
  - Two follow-up REQs filed (PERF-11 closed code-verified, PERF-12 deferred to v2.3)
affects:
  - v2.2 CI/Sparkle/Homebrew phases unblocked — v2.1 debt table now empty
  - REQUIREMENTS.md traceability table updated with PERF-11/PERF-12 entries

tech-stack:
  patterns:
    - "Instruments GUI capture + xctrace export XPath for os-signpost interval extraction (automated post-capture analysis workaround for PITFALLS #16)"
    - "Warm-state measurement convention: cold-launch runs discarded as attach/dyld overhead; steady-state runs used as canonical numbers"
    - "Code-verified closeout path for architecturally-non-measurable perf items (PERF-11 → keep-capacity reuse not observable in per-window-per-renderer pattern)"

key-files:
  created:
    - docs/perf/v2.1-measurements.md
    - docs/perf/test-files/simple-50kb.md
    - docs/perf/test-files/forced-wkwebview-50kb.md
    - docs/perf/test-files/forced-wkwebview-50kb-b.md
    - docs/perf/test-files/large-100kb.md
  modified:
    - .planning/phases/06-vendored-cmark/06-VERIFICATION.md
    - .planning/phases/07-wkwebview-pool/07-VERIFICATION.md
    - .planning/phases/07-wkwebview-pool/07-HUMAN-UAT.md
    - .planning/phases/08-streaming-pipeline/08-VERIFICATION.md
    - .planning/phases/08-streaming-pipeline/08-HUMAN-UAT.md
    - .planning/phases/09-native-text-rendering/09-VERIFICATION.md
    - .planning/REQUIREMENTS.md

key-decisions:
  - "PERF-04 canonical value taken from Run 3 (115.68 ms) not Run 1 (435.34 ms) — Run 1 absorbed Instruments-attach + cold dyld + font-registration overhead; Run 3 reflects realistic warm-state user experience"
  - "PERF-11 closed as code-verified rather than measurable: `removeAll(keepingCapacity: true)` is present and correct in source, but per-window-per-renderer architecture means no runtime code path exercises the reuse — filing a fix would require an architectural change out of scope for v2.1"
  - "PERF-12 filed as incidental finding (>4 GB persistent heap after 5 opens of a 100 KB file) but explicitly not blocking v2.1 closeout — deferred to v2.3 investigation"
  - "Trace bundles NOT committed to git (~80 MB); filenames and runs recorded textually in docs/perf/v2.1-measurements.md for reproducibility"

patterns-established:
  - "Quality-closeout phase template: capture measurements → sign UAT → flip VERIFICATION status → file escalations rather than fix in-phase (used for future milestone-closeout passes)"

requirements-completed:
  - PERF-04
  - PERF-05
  - PERF-06
  - PERF-07
  - UAT-V21-01
  - UAT-V21-02
  - VRF-V21-01
  - VRF-V21-02
  - VRF-V21-03
  - VRF-V21-04

duration: ~3.5h developer time across 2026-04-18 → 2026-04-19
started: 2026-04-18
completed: 2026-04-19
---

# Phase 10 Plan 01: v2.1 Quality Closeout Summary

**All v2.1 perf debt measured under Instruments (3/4 PASS, 1 closed code-verified) and every `human_needed` VERIFICATION flipped to `verified` — v2.2 release-automation work proceeds on a clean v2.1 baseline.**

## Performance

- **Duration:** ~3.5 hours developer time (Instruments capture + UAT walkthrough + VERIFICATION reconciliation)
- **Started:** 2026-04-18
- **Completed:** 2026-04-19
- **Tasks:** 14/14 completed (plan marked `autonomous: false` — human-driven throughout)
- **Files modified:** 8 (1 new measurement doc + 4 test fixtures + 7 planning-doc updates + REQUIREMENTS.md)

## Accomplishments

- Captured **PERF-04 / PERF-05 / PERF-06** on M4 Max / macOS 26.4 via Instruments Logging template — all three PASS with healthy margins (34 ms, 48 ms, 12 ms below their respective targets)
- Investigated **PERF-07** (STRM-02 buffer reuse) under Allocations template — discovered the `keepingCapacity` reuse is architecturally non-observable in MDViewer's per-window-per-renderer pattern; closed as code-verified rather than runtime-measured
- Flipped all four Phase 06–09 VERIFICATION.md files from `status: human_needed` → `status: verified`, each with a dated Closeout Note pointing to the measurement entry or follow-up REQ
- Signed off three HUMAN-UAT scenarios (Phase 07: PERF-03 pool open; Phase 08: STRM-02 + PERF-01) with PASS results
- Filed PERF-11 and PERF-12 in REQUIREMENTS.md for v2.3+ triage — no in-phase fixes, per plan escalation rule

## Task Commits

The plan was committed across four atomic commits (tasks bundled by logical closeout stage):

1. **Task 1–2: Measurement scaffold + test fixtures** — `2ad9d0d` (docs: prep Phase 10 — measurement skeleton + test fixtures)
2. **Tasks 3–6 + 8–9: Instruments captures + UAT sign-off for 3/4 PERF targets** — `461a55e` (docs(10): close out v2.1 quality debts — 3/4 PERF PASS, 1 deferred)
3. **Tasks 6 + 7: PERF-07 code-verified closeout + PERF-12 incidental finding** — `91ae8a1` (docs(10): close PERF-11 code-verified; file PERF-12 incidental heap finding)
4. **Tasks 10, 11, 12, 13, 14: Phase 06 + 09 visual verifications + final reconciliation** — `9d1823b` (docs(10): close Phase 06 + 09 visual verifications — Phase 10 fully complete)

**Plan metadata:** this SUMMARY.md plus Phase 08 HUMAN-UAT frontmatter flip (`partial` → `complete`, which Task 9 missed at original commit time) — committed together at phase close.

## Files Created/Modified

**Created:**
- `docs/perf/v2.1-measurements.md` (85 lines) — Canonical v2.1 measurement record with 4 entries, hardware details, trace filenames, and follow-up REQ pointers
- `docs/perf/test-files/simple-50kb.md` — 50 KB native-path fixture (no mermaid/tables)
- `docs/perf/test-files/forced-wkwebview-50kb.md` + `-b.md` — 50 KB fixtures containing GFM tables to force WKWebView routing (PERF-04 + PERF-06 second-open pair)
- `docs/perf/test-files/large-100kb.md` — 100 KB fixture for PERF-07 Allocations capture

**Modified:**
- `.planning/phases/06-vendored-cmark/06-VERIFICATION.md` — `status: verified`; Closeout Note records 2026-04-19 visual confirmation (h1/h2/h3/GFM table/mermaid/bold/italic/link rendered identically to pre-Phase-6 baseline)
- `.planning/phases/07-wkwebview-pool/07-VERIFICATION.md` — `status: verified`; Closeout Note points to entry #3 (PERF-06 PASS @ 88.31 ms)
- `.planning/phases/07-wkwebview-pool/07-HUMAN-UAT.md` — Test 1 (PERF-03) marked PASS @ 88.31 ms; frontmatter `status: complete`, `passed: 1`
- `.planning/phases/08-streaming-pipeline/08-VERIFICATION.md` — `status: verified`; Closeout Note points to entries #1 (PERF-04 PASS) and #4 (PERF-07 code-verified); references PERF-11/PERF-12 follow-ups
- `.planning/phases/08-streaming-pipeline/08-HUMAN-UAT.md` — Test 1 (STRM-02) + Test 2 (PERF-01) marked PASS; frontmatter `status: complete`, `passed: 2`
- `.planning/phases/09-native-text-rendering/09-VERIFICATION.md` — `status: verified`; Closeout Note points to entry #2 (PERF-05 PASS @ 51.51 ms) and records NATV-03 visual font confirmation
- `.planning/REQUIREMENTS.md` — Added PERF-11 (closed code-verified) and PERF-12 (deferred to v2.3) to section A; updated Traceability table

## Deviations from Plan

**One minor deviation, one documented-at-time judgment call:**

1. **PERF-07 closure method** — Plan Task 6 anticipated a binary PASS/FAIL on heap-allocation behavior. In practice, the trace surfaced an architectural finding (per-window-per-renderer means `keepingCapacity` reuse is never exercised) that made runtime measurement moot. Closure path: filed PERF-11 with a `closed` status and a code-evidence note rather than a `pending` follow-up. The escalation rule still applied — just with a different resolution kind than the plan envisioned.
2. **Run 1 PERF-04 anomaly** — Plan Task 3 did not anticipate that the first run after Instruments attach would be ~4× slower than steady state. Documented the anomaly inline in `v2.1-measurements.md` ("Run 1 anomaly note" section) and used Run 3's 115.68 ms as the canonical number. This is a measurement-methodology lesson worth preserving for any future manual perf captures.

No other deviations. All 14 tasks executed; escalation rule (file-new-REQ vs fix-in-phase) honored twice (PERF-11, PERF-12).

## Known Stubs / Follow-Ups

- **PERF-12** remains open in REQUIREMENTS.md, targeted at v2.3. It was an incidental finding from the PERF-07 Allocations trace (~4 GB persistent heap after 5 opens of a 100 KB file); hypotheses to test include WebContent process retention, font glyph cache growth, and Mermaid script residue. Not blocking v2.2.
- No other stubs. Trace bundles (`~/Desktop/perf-04-wkwebview-warm.trace`, `~/Desktop/perf-7.trace`) live on the developer Mac but are intentionally NOT in git — only their filenames and run indices are recorded in `v2.1-measurements.md` for reproducibility.

## Verification

All five roadmap success criteria hold:

1. **`docs/perf/v2.1-measurements.md` exists with four numbered entries** — verified: `grep -c "^## [1-4]\." docs/perf/v2.1-measurements.md` → `4`.
2. **WKWebView warm launch ≤150 ms AND NSTextView warm launch ≤100 ms** — verified: 115.68 ms and 51.51 ms respectively (entry #1 and #2).
3. **Phase 07 and Phase 08 HUMAN-UAT files have every pending scenario marked PASS/FAIL** — verified: `grep -l "result: \[pending\]" .planning/phases/0[7-8]-*/*-HUMAN-UAT.md` returns no matches; both files have `status: complete` in frontmatter.
4. **Phase 06–09 VERIFICATION.md files no longer contain `human_needed`** — verified: `grep -l "status: human_needed" .planning/phases/0[6-9]-*/*-VERIFICATION.md` returns no matches; all four files show `status: verified`.
5. **Any new requirement filed is recorded in REQUIREMENTS.md** — verified: PERF-11 (checkbox `[x]`, closed code-verified) and PERF-12 (checkbox `[ ]`, deferred to v2.3) present in section A with reasoning captured inline.

## Threat Surface Scan

No new network endpoints, auth paths, file-access patterns, or schema changes. The only new artifacts are documentation files (perf record + test fixtures + planning-doc updates). Test fixtures under `docs/perf/test-files/` are synthetic markdown intentionally committed to the repo for reproducible measurement; they contain no secrets or sensitive content. No code or entitlement changes.
