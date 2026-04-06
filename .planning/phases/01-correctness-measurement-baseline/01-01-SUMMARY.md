---
phase: 01-correctness-measurement-baseline
plan: 01
subsystem: memory, instrumentation
tags: [WKWebView, OSSignposter, retain-cycle, os_signpost, profiling]

# Dependency graph
requires: []
provides:
  - WeakScriptMessageProxy breaks WKUserContentController retain cycle
  - OSSignposter instrumentation for file-read, parse, chunk-split, chunk-inject, open-to-paint
  - deinit verification logging for WebContentView and MarkdownWindow
  - hasProcessedFirstPaint guard against double firstPaint processing
affects: [02-large-file-memory, 03-launch-speed, 04-mermaid-script-loading, 05-window-management]

# Tech tracking
tech-stack:
  added: [OSSignposter (os framework)]
  patterns: [WeakScriptMessageProxy for WKScriptMessageHandler retain cycle, module-level signposter constant, signpost interval per pipeline stage]

key-files:
  created: []
  modified:
    - MDViewer/WebContentView.swift
    - MDViewer/MarkdownWindow.swift
    - MDViewer/MarkdownRenderer.swift
    - MDViewer/AppDelegate.swift

key-decisions:
  - "Module-level renderingSignposter constant -- MarkdownRenderer is stateless, instance property would be wrong"
  - "File-level appSignposter in AppDelegate for open-to-paint interval -- separate from renderingSignposter but same subsystem/category"
  - "ObjectIdentifier-keyed dictionary for in-flight paint states -- supports concurrent window opens"

patterns-established:
  - "WeakScriptMessageProxy: nested private class in WebContentView for WKScriptMessageHandler retain cycle breaking"
  - "OSSignposter intervals: beginInterval/endInterval pairs around each pipeline stage"
  - "DEBUG-gated deinit logging: print with ObjectIdentifier for deallocation verification"

requirements-completed: [MEM-01, LAUNCH-01]

# Metrics
duration: 4min
completed: 2026-04-06
---

# Phase 01 Plan 01: Fix WKWebView Retain Cycle and Add OSSignposter Pipeline Instrumentation Summary

**WeakScriptMessageProxy breaks WKWebView retain cycle, OSSignposter instruments five pipeline stages (file-read, parse, chunk-split, chunk-inject, open-to-paint) for Instruments profiling**

## Performance

- **Duration:** 4 min
- **Started:** 2026-04-06T08:29:38Z
- **Completed:** 2026-04-06T08:33:57Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Broke WKUserContentController retain cycle via WeakScriptMessageProxy so closing windows releases all WKWebView memory
- Added deinit to both WebContentView and MarkdownWindow with DEBUG logging for deallocation verification
- Added hasProcessedFirstPaint guard preventing double firstPaint message processing
- Gated developerExtrasEnabled behind #if DEBUG
- Instrumented five pipeline stages with OSSignposter: file-read, parse, chunk-split, chunk-inject, and open-to-paint
- All signposts use subsystem "com.mdviewer.app" with category "RenderingPipeline" for Instruments visibility

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix WKWebView retain cycle and add deallocation verification** - `d29c47e` (fix)
2. **Task 2: Add OSSignposter pipeline instrumentation** - `07bba4d` (feat)

## Files Created/Modified
- `MDViewer/WebContentView.swift` - WeakScriptMessageProxy, deinit with cleanup, hasProcessedFirstPaint guard, chunk-inject signpost
- `MDViewer/MarkdownWindow.swift` - deinit with DEBUG logging
- `MDViewer/MarkdownRenderer.swift` - renderingSignposter constant, file-read/parse/chunk-split intervals
- `MDViewer/AppDelegate.swift` - appSignposter, open-to-paint interval spanning openFile to firstPaint

## Decisions Made
- Module-level `renderingSignposter` constant rather than instance property on MarkdownRenderer (renderer is stateless by design)
- File-level `appSignposter` in AppDelegate for open-to-paint interval, separate from renderingSignposter but same subsystem/category for unified Instruments view
- `ObjectIdentifier`-keyed dictionary `openToPaintStates` to track in-flight paint states, supporting concurrent window opens

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all functionality is fully wired.

## Next Phase Readiness
- Retain cycle fix means all memory measurements in Phase 2+ will be valid
- OSSignposter instrumentation provides profiling data for Phase 2 (large file memory), Phase 3 (launch speed)
- Baseline measurements (cold launch, warm launch, peak RSS) can now be recorded using Instruments

## Self-Check: PASSED
- All 5 files exist
- Both task commits (d29c47e, 07bba4d) found in git history
- Debug and Release builds succeed

---
*Phase: 01-correctness-measurement-baseline*
*Completed: 2026-04-06*
