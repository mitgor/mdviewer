---
phase: 03-launch-speed
plan: 01
subsystem: infra
tags: [ossignposter, signpost, instruments, launch-time, measurement]

# Dependency graph
requires:
  - phase: 01-correctness-measurement-baseline
    provides: OSSignposter pattern (appSignposter, open-to-paint interval)
provides:
  - launch-to-paint signpost interval from main.swift to first paint
  - hasCompletedFirstLaunchPaint guard for one-shot interval end
  - No-file timeout to prevent infinite signpost intervals
affects: [03-launch-speed]

# Tech tracking
tech-stack:
  added: []
  patterns: [module-level signpost globals in main.swift for cross-file interval tracking]

key-files:
  created: []
  modified: [MDViewer/main.swift, MDViewer/AppDelegate.swift]

key-decisions:
  - "Module-level launchSignposter and launchSignpostState in main.swift for earliest possible measurement point"
  - "Boolean guard (hasCompletedFirstLaunchPaint) ensures interval ends exactly once"
  - "5-second timeout prevents infinite interval when app launched without a file"

patterns-established:
  - "Cross-file signpost: begin in main.swift, end in AppDelegate via module-level constants"

requirements-completed: [LAUNCH-03]

# Metrics
duration: 1min
completed: 2026-04-06
---

# Phase 03 Plan 01: Launch-to-Paint Signpost Summary

**OSSignposter launch-to-paint interval from main.swift entry to first WebContentView paint callback, with one-shot guard and no-file timeout**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-06T20:13:39Z
- **Completed:** 2026-04-06T20:14:37Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments
- Added launch-to-paint signpost interval spanning from the earliest point in main.swift to the first paint callback in AppDelegate
- One-shot guard (hasCompletedFirstLaunchPaint) prevents double-end of the signpost interval
- 5-second timeout ends the signpost if no file is opened, preventing infinite intervals in Instruments
- Existing open-to-paint signpost preserved unchanged

## Task Commits

Each task was committed atomically:

1. **Task 1: Add launch-to-paint signpost in main.swift and end it in AppDelegate** - `038d536` (feat)

## Files Created/Modified
- `MDViewer/main.swift` - Added `import os`, `launchSignposter` and `launchSignpostState` module-level constants
- `MDViewer/AppDelegate.swift` - Added `hasCompletedFirstLaunchPaint` guard, signpost end in first-paint callback, 5-second no-file timeout

## Decisions Made
- Module-level constants in main.swift (not AppDelegate) -- earliest possible measurement point before any NSApplication setup
- Boolean guard over counter -- simpler, sufficient for one-shot semantics
- 5-second timeout for no-file case -- generous enough for normal launch but prevents infinite intervals in profiling

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None -- no external service configuration required.

## Next Phase Readiness
- Launch-to-paint measurement infrastructure is in place
- Ready for Plan 02 (WKWebView pre-warm optimization) with data from Instruments profiling
- The signpost interval will provide the baseline timing needed before any optimization work

---
*Phase: 03-launch-speed*
*Completed: 2026-04-06*

## Self-Check: PASSED
- MDViewer/main.swift: FOUND
- MDViewer/AppDelegate.swift: FOUND
- 03-01-SUMMARY.md: FOUND
- Commit 038d536: FOUND
