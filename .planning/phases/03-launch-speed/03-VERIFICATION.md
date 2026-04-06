---
phase: 03-launch-speed
verified: 2026-04-06T23:00:00Z
status: gaps_found
score: 5/6 must-haves verified
re_verification:
  previous_status: gaps_found
  previous_score: 4/6
  gaps_closed:
    - "03-PROFILING.md contains actual measured values — all estimate disclaimers and (est.) labels removed"
    - "LAUNCH-03 sub-100ms warm launch target is explicitly confirmed or refuted with measured data"
  gaps_remaining:
    - "LAUNCH-03 sub-100ms warm launch target is NOT MET — measured at 184.50ms"
  regressions: []
gaps:
  - truth: "Warm launch to first visible content completes in under 100ms on Apple Silicon (measured via os_signpost)"
    status: failed
    reason: "Actual Instruments measurement recorded 184.50ms warm launch-to-paint on M4 Max, macOS 26.3.1 — 84% over the 100ms target. WKWebView pre-warm is active in this measurement. The bottleneck is the open-to-paint pipeline (139ms), dominated by WKWebView loadHTMLString and rendering. REQUIREMENTS.md marks LAUNCH-03 as [x] complete, which is incorrect — the requirement asserts sub-100ms performance and 184.50ms does not satisfy it."
    artifacts:
      - path: ".planning/phases/03-launch-speed/03-PROFILING.md"
        issue: "Contains confirmed measurement showing 184.50ms warm launch — LAUNCH-03 NOT MET section present. The requirement cannot be checked off as complete."
      - path: ".planning/REQUIREMENTS.md"
        issue: "LAUNCH-03 marked [x] complete at line 23 and listed as Complete in the traceability table at line 56. This is inconsistent with the measured 184.50ms result — the requirement text says sub-100ms and the measurement does not satisfy it."
    missing:
      - "Further optimization work to close the 84.5ms gap (three paths identified in 03-PROFILING.md: pre-load template into pre-warmed WKWebView, reduce initial HTML payload, add granular sub-intervals to isolate dominant stage)"
      - "REQUIREMENTS.md LAUNCH-03 checkbox and traceability table corrected to reflect the requirement is not yet satisfied"
      - "Phase 3 cannot be closed until LAUNCH-03 is either met via optimization or the target is formally revised"
---

# Phase 3: Launch Speed — Verification Report (Re-verification)

**Phase Goal:** Warm launch to first visible content completes in under 100ms on Apple Silicon
**Verified:** 2026-04-06T23:00:00Z
**Status:** gaps_found
**Re-verification:** Yes — after Plan 03-03 gap closure (Instruments profiling session)

## Re-verification Summary

| Item | Previous | Now |
|------|----------|-----|
| Profiling data in 03-PROFILING.md | Estimates only | Actual measured (Instruments os_signpost, M4 Max) |
| LAUNCH-03 confirmation status | Unconfirmed (no measurement) | Definitively NOT MET (184.50ms vs 100ms target) |
| Gaps closed | — | 2 of 2 previous gaps resolved |
| Gaps remaining | 2 | 1 (the performance target itself is not achieved) |
| Score | 4/6 | 5/6 |

The two previous gaps are closed: 03-PROFILING.md now contains actual Instruments measurements and the LAUNCH-03 status is explicitly documented as not met. However, closing those gaps reveals the underlying gap was always the performance target itself — 184.50ms is not under 100ms.

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | launch-to-paint signpost interval appears in Instruments for the full app-launch-to-content pipeline | VERIFIED | main.swift line 8: `launchSignposter.beginInterval("launch-to-paint")`; AppDelegate.swift line 114: `launchSignposter.endInterval("launch-to-paint", launchSignpostState)` |
| 2 | First paint ends the launch-to-paint interval exactly once (no double-end, no infinite interval) | VERIFIED | AppDelegate.swift lines 112-114: `if !hasCompletedFirstLaunchPaint` guard wraps the endInterval call |
| 3 | Launch signpost is harmless when no file is opened (no infinite interval) | VERIFIED | AppDelegate.swift lines 41-43: 5-second asyncAfter fallback calls endInterval if `hasCompletedFirstLaunchPaint` is still false |
| 4 | WKWebView pre-warm is implemented and active in the measured launch path | VERIFIED | AppDelegate.swift lines 17, 26, 170-172: preWarmedContentView created in applicationDidFinishLaunching, consumed and nilled in displayResult; confirmed active in 184.50ms measurement |
| 5 | 03-PROFILING.md contains actual measured values, not estimates | VERIFIED | Commit 5fa974a; grep for "est." returns 0; header reads "Measured values from Instruments os_signpost profiling"; "LAUNCH-03 NOT MET" and "Further Optimization Needed" present |
| 6 | Warm launch to first visible content completes in under 100ms on Apple Silicon (measured via os_signpost) | FAILED | Instruments measurement on M4 Max, macOS 26.3.1: launch-to-paint = 184.50ms. Target is 100ms. 84% over target. |

**Score:** 5/6 truths verified

---

### Required Artifacts

#### From 03-01-PLAN.md

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/main.swift` | launchSignposter and launchSignpostState globals; beginInterval at process start | VERIFIED | Lines 4-8: OSSignposter created, beginInterval("launch-to-paint") called immediately |
| `MDViewer/AppDelegate.swift` | hasCompletedFirstLaunchPaint guard and signpost end call | VERIFIED | Line 16: property declared false; lines 112-114: one-shot guard calls endInterval |

#### From 03-02-PLAN.md

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/AppDelegate.swift` | preWarmedContentView property and reuse in displayResult | VERIFIED | Line 17: property declared; line 26: created in applicationDidFinishLaunching; lines 170-172: consumed in displayResult; line 48: nilled in applicationWillTerminate |
| `.planning/phases/03-launch-speed/03-PROFILING.md` | Actual measured timing data replacing all estimates | VERIFIED | No "(est.)" labels remain; header states measured; device/macOS/date filled in; "LAUNCH-03 NOT MET" section present; "Further Optimization Needed" documented |

#### From 03-03-PLAN.md

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `.planning/phases/03-launch-speed/03-PROFILING.md` | Actual measured cold and warm launch timing data | VERIFIED (warm only) | Warm: 184.50ms measured. Cold: not measured (acknowledged in 03-03-SUMMARY.md as a deviation). Plan success criteria required both; cold was not captured in this session. |

**Note on cold launch:** Plan 03-03 acceptance criteria included cold launch measurement. The 03-03-SUMMARY.md acknowledges "Cold launch was not measured in this session." This is a minor deviation within the plan but does not affect the phase goal directly — the phase goal concerns warm launch only.

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `MDViewer/main.swift` | `MDViewer/AppDelegate.swift` | Module-level launchSignposter and launchSignpostState referenced in AppDelegate | WIRED | AppDelegate.swift lines 43 and 114 both call `launchSignposter.endInterval("launch-to-paint", launchSignpostState)` — module-level constants from main.swift, accessible in the same Swift module without import |
| `MDViewer/AppDelegate.swift` | `MDViewer/WebContentView.swift` | preWarmedContentView created eagerly, reused in displayResult for first file open | WIRED | Line 26: created; lines 170-172: conditionally consumed; `contentView.delegate = self` and `contentView.loadContent(...)` follow the same path for both pre-warmed and fresh view |

---

### Data-Flow Trace (Level 4)

Not applicable. Phase 3 artifacts are performance instrumentation (signpost) and launch optimization (pre-warm), not data-rendering components. No dynamic user data flows through these artifacts.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Release build compiles cleanly | `xcodebuild -project MDViewer.xcodeproj -scheme MDViewer -configuration Release build` | `** BUILD SUCCEEDED **` | PASS |
| launchSignposter begins in main.swift | `grep "beginInterval.*launch-to-paint" MDViewer/main.swift` | Line 8 matches | PASS |
| launchSignposter ends exactly once in AppDelegate | `grep "endInterval.*launch-to-paint" MDViewer/AppDelegate.swift` | Lines 43 and 114, both inside `if !hasCompletedFirstLaunchPaint` blocks | PASS |
| preWarmedContentView consumed before falling back to fresh WebContentView | `grep "preWarmedContentView" MDViewer/AppDelegate.swift` | Lines 17, 26, 48, 170, 172 — nil-on-use pattern present | PASS |
| 03-PROFILING.md contains no estimate labels | `grep -c "est\." 03-PROFILING.md` | 0 | PASS |
| 03-PROFILING.md contains measured-data header | `grep "Measured" 03-PROFILING.md` | Lines 7 and 9 match | PASS |
| 03-PROFILING.md contains explicit LAUNCH-03 status | `grep "LAUNCH-03 NOT MET" 03-PROFILING.md` | Line 43 matches | PASS |
| Commit 5fa974a exists in repository | `git log --oneline \| grep 5fa974a` | `5fa974a docs(03-03): record actual Instruments profiling measurements — warm launch 184.50ms` | PASS |
| Warm launch under 100ms | Instruments os_signpost measurement (human-run) | 184.50ms — 84% over target | FAIL |

---

### Requirements Coverage

Plan 03-01-PLAN.md declares: `requirements: [LAUNCH-03]`
Plan 03-02-PLAN.md declares: `requirements: [LAUNCH-02, LAUNCH-03]`
Plan 03-03-PLAN.md declares: `requirements: [LAUNCH-02, LAUNCH-03]`

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| LAUNCH-02 | 03-02, 03-03 | WKWebView pre-warmed at app launch — reused for first file open | SATISFIED | AppDelegate.swift implements preWarmedContentView: created in applicationDidFinishLaunching, consumed and nilled for first file open. Pre-warm confirmed active in 184.50ms measured run. 03-03-SUMMARY.md `requirements-completed` lists LAUNCH-02. |
| LAUNCH-03 | 03-01, 03-02, 03-03 | Sub-100ms warm launch to first visible content on Apple Silicon | NOT SATISFIED | Instruments measurement: 184.50ms warm launch-to-paint on M4 Max. Requirement asserts sub-100ms; measured value is 84% over target. 03-03-SUMMARY.md correctly omits LAUNCH-03 from `requirements-completed`. |

**Discrepancy in REQUIREMENTS.md:** LAUNCH-03 is marked `[x]` complete (line 23) and listed as Status=Complete in the traceability table (line 56). This conflicts with the measured result. The 03-03-SUMMARY.md correctly records `requirements-completed: [LAUNCH-02]` (omitting LAUNCH-03), but REQUIREMENTS.md was not updated to reflect the unmet status.

**Orphaned requirements check:** REQUIREMENTS.md maps no additional requirement IDs to Phase 3 beyond LAUNCH-02 and LAUNCH-03. No orphaned requirements.

---

### Anti-Patterns Found

Files scanned: `MDViewer/main.swift`, `MDViewer/AppDelegate.swift`, `.planning/phases/03-launch-speed/03-PROFILING.md`, `.planning/REQUIREMENTS.md`

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `.planning/REQUIREMENTS.md` | 23, 56 | LAUNCH-03 marked `[x]` complete and Status=Complete, contradicting the 184.50ms measurement | WARNING | Misleading state — anyone reading REQUIREMENTS.md will conclude the performance target is met when it is not. Does not affect the running app but corrupts the project's source of truth for requirement status. |

No blocking anti-patterns in source code. `main.swift` and `AppDelegate.swift` are clean — no TODOs, placeholders, or stub return patterns.

---

### Human Verification Required

#### 1. Cold Launch Measurement

**Test:** Run `sudo purge` to clear disk cache, then launch MDViewer under Instruments os_signpost with the same Release build used for warm measurement. Record the `launch-to-paint` interval duration.

**Expected:** Cold launch is measurably higher than the 184.50ms warm launch (estimated 50-80ms higher per industry data). Record the value in 03-PROFILING.md in the "Cold launch-to-paint" row currently showing "Not measured."

**Why human:** Cold launch requires cache purge (`sudo purge` or reboot) then immediate Instruments recording — cannot be automated without running the app under a profiling host.

#### 2. Optimization Path Decision

**Test:** Review the three optimization paths documented in the "Further Optimization Needed" section of 03-PROFILING.md and decide which to pursue, or whether to revise the 100ms target.

**Expected:** Either (a) a new plan is created to close the 84.5ms gap, or (b) the LAUNCH-03 target is formally revised (e.g., to 200ms) and REQUIREMENTS.md updated to reflect the new target and uncheck the box until confirmed.

**Why human:** This is a product decision — choosing between pre-loading template HTML into the pre-warmed WKWebView (high complexity), reducing payload size (medium complexity), or revising the target (low complexity) requires judgment that cannot be automated.

---

### Gaps Summary

**Plans 01 and 02 are fully verified.** Signpost instrumentation and WKWebView pre-warm are implemented correctly, build cleanly, and the pre-warm is confirmed active in the actual profiling run.

**Plan 03-03 (profiling gap closure) achieved its objective.** The previous gaps — "no actual profiling data" and "LAUNCH-03 unconfirmed" — are both closed. 03-PROFILING.md now contains real Instruments measurements with no estimate labels. Commit 5fa974a is confirmed in the repository. Cold launch was not recorded, which is a deviation from the plan's acceptance criteria but does not affect the phase goal.

**Phase goal: not achieved.** The goal is warm launch under 100ms. The measurement is 184.50ms — 84% over target. The pre-warm optimization moves WKWebView init off the critical path but is insufficient alone. The dominant bottleneck is open-to-paint (139ms), which is the WKWebView HTML rendering pipeline.

Two actions are needed to resolve this phase:

1. Pursue further optimization (three paths documented in 03-PROFILING.md: template pre-load into pre-warmed view, smaller initial HTML payload, granular sub-intervals for stage isolation), or formally revise the 100ms target.
2. Correct REQUIREMENTS.md: uncheck LAUNCH-03 and update the traceability table to Pending until the target is either met or revised.

---

_Verified: 2026-04-06T23:00:00Z_
_Verifier: Claude (gsd-verifier)_
