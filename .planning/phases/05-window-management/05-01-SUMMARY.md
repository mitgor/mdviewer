---
phase: 05-window-management
plan: 01
subsystem: ui
tags: [appkit, nswindow, autosave, cascade, window-management]

requires:
  - phase: none
    provides: n/a
provides:
  - Per-file window position persistence via setFrameAutosaveName
  - Multi-window cascade positioning via cascadeTopLeft(from:)
affects: []

tech-stack:
  added: []
  patterns:
    - "Per-file autosave names derived from standardized file URL path"
    - "AppKit native cascadeTopLeft(from:) with static lastCascadePoint tracking"

key-files:
  created: []
  modified:
    - MDViewer/MarkdownWindow.swift

key-decisions:
  - "Per-file autosave name format MDViewer:{absolutePath} -- unique per file, uses standardizedFileURL for canonical paths"
  - "Frame change detection to skip cascade when autosave restores position -- compare frame before/after setFrameAutosaveName"

patterns-established:
  - "setFrameAutosaveName for window persistence -- AppKit handles UserDefaults read/write automatically"

requirements-completed: [WIN-01, WIN-02]

duration: 1min
completed: 2026-04-06
---

# Phase 05 Plan 01: Per-file Window Persistence and Cascade Summary

**Per-file window position/size persistence via AppKit autosave names and proper multi-window cascading via cascadeTopLeft**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-06T22:10:08Z
- **Completed:** 2026-04-06T22:11:30Z
- **Tasks:** 2 (1 auto + 1 checkpoint auto-approved)
- **Files modified:** 1

## Accomplishments
- Each file gets a unique autosave name derived from its absolute path, enabling independent position persistence
- New windows without saved positions cascade properly using NSWindow.cascadeTopLeft(from:)
- Windows with saved positions restore to their saved location without cascading
- Removed stub loadSavedFrame() and non-cascading cascadedOrigin() methods

## Task Commits

Each task was committed atomically:

1. **Task 1: Per-file frame autosave and cascade positioning** - `12f9782` (feat)
2. **Task 2: Verify window persistence and cascading behavior** - auto-approved checkpoint (user will verify manually after waking)

## Files Created/Modified
- `MDViewer/MarkdownWindow.swift` - Replaced shared frameSaveKey with per-file autosaveName, added cascadeTopLeft positioning, removed stubs

## Decisions Made
- Used `MDViewer:{absolutePath}` as autosave name format -- simple, unique per file, uses standardizedFileURL for canonical path resolution
- Detect autosave frame restoration by comparing frame before/after setFrameAutosaveName call -- avoids cascading windows that already have a saved position

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Checkpoint: Auto-approved

Task 2 (human-verify checkpoint) was auto-approved per user instruction ("proceed automatically -- user is asleep"). User will verify window persistence and cascading behavior manually when they wake up:
1. Open a file, move/resize, quit, reopen same file -- should restore position
2. Open a different file -- should not share first file's position
3. Open 3 files simultaneously -- should cascade visibly

## Next Phase Readiness
- Window management complete for WIN-01 and WIN-02 requirements
- No blockers for subsequent phases

## Self-Check: PASSED

- MDViewer/MarkdownWindow.swift: FOUND
- 05-01-SUMMARY.md: FOUND
- Commit 12f9782: FOUND

---
*Phase: 05-window-management*
*Completed: 2026-04-06*
