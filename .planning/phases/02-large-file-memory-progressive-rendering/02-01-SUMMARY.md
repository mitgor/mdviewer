---
phase: 02-large-file-memory-progressive-rendering
plan: 01
subsystem: rendering, memory
tags: [mappedIfSafe, Data, chunkHTML, byte-size-splitting, OSSignposter, cmark-gfm]

# Dependency graph
requires:
  - phase: 01-correctness-measurement-baseline
    provides: OSSignposter instrumentation for file-read, parse, chunk-split intervals
provides:
  - Memory-mapped file read via Data(contentsOf:options:.mappedIfSafe)
  - Byte-size N-chunk HTML splitting at 64KB block-tag boundaries
  - Test infrastructure fix for hosted XCTest with macOS app
affects: [02-02-callAsyncJavaScript, 03-launch-speed, 04-mermaid-script-loading]

# Tech tracking
tech-stack:
  added: []
  patterns: [byte-size chunk splitting at block-tag boundaries, memory-mapped file I/O via mappedIfSafe]

key-files:
  created:
    - MDViewer.xcodeproj/xcshareddata/xcschemes/MDViewer.xcscheme
  modified:
    - MDViewer/MarkdownRenderer.swift
    - MDViewerTests/MarkdownRendererTests.swift
    - MDViewer/AppDelegate.swift

key-decisions:
  - "64KB chunkByteLimit measured with .utf8.count not NSString.length -- UTF-8 byte count is the correct metric for data transfer size"
  - "mappedIfSafe over alwaysMapped -- gracefully falls back to normal read on unsafe volumes"
  - "XCTest hosted fix via applicationShouldTerminateAfterLastWindowClosed returning false during tests"

patterns-established:
  - "Byte-size chunk splitting: walk block-tag regex matches accumulating utf8.count, split at previous boundary when exceeding limit"
  - "Memory-mapped read: Data(contentsOf:options:.mappedIfSafe) then String(data:encoding:.utf8) for large file reads"

requirements-completed: [MEM-02, RENDER-01]

# Metrics
duration: 15min
completed: 2026-04-06
---

# Phase 02 Plan 01: Memory-Mapped File Read and Byte-Size N-Chunk Splitting Summary

**Memory-mapped file read via mappedIfSafe replaces heap-allocating String(contentsOf:), and byte-size 64KB N-chunk splitting replaces fixed 2-chunk block-count approach for true progressive rendering**

## Performance

- **Duration:** 15 min
- **Started:** 2026-04-06T09:00:34Z
- **Completed:** 2026-04-06T09:16:03Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Replaced `String(contentsOf:encoding:.utf8)` with `Data(contentsOf:options:.mappedIfSafe)` + `String(data:encoding:.utf8)` to avoid double heap allocation for large files
- Replaced `chunkThreshold = 50` block-count splitting with `chunkByteLimit = 64 * 1024` byte-size splitting that produces N chunks at block-tag boundaries
- Small content (<64KB) returns single chunk; large content produces multiple chunks each roughly <=64KB
- All signposter intervals (file-read, parse, chunk-split) preserved unchanged
- Fixed test infrastructure: tests now run successfully in hosted mode with macOS app
- Added 3 new tests: block-boundary verification, memory-mapped file read, byte size verification

## Task Commits

Each task was committed atomically:

1. **Task 1: Memory-mapped file read and byte-size N-chunk splitting** - `d2a4ae6` (test: RED), `8c5ec22` (feat: GREEN)
2. **Task 2: Update tests for N-chunk splitting behavior** - `c2bbedd` (test)

## Files Created/Modified
- `MDViewer/MarkdownRenderer.swift` - Memory-mapped read in renderFullPage(fileURL:), byte-size chunkHTML with 64KB limit
- `MDViewerTests/MarkdownRendererTests.swift` - Updated testChunkingSplitsLargeContent, added testChunkSplitsAtBlockBoundaries, testMemoryMappedFileRead, testChunkByteSizeVerification
- `MDViewer/AppDelegate.swift` - applicationShouldTerminateAfterLastWindowClosed returns false during XCTest hosting
- `MDViewer.xcodeproj/xcshareddata/xcschemes/MDViewer.xcscheme` - Shared scheme with test target configured

## Decisions Made
- Used `.utf8.count` for byte measurement per Pitfall 4 from research (NSString.length is UTF-16 code units, not UTF-8 bytes)
- Used `mappedIfSafe` over `alwaysMapped` for graceful fallback on unsafe volumes
- Fixed test infrastructure by preventing app termination during tests and adding shared xcscheme

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed test infrastructure for hosted XCTest**
- **Found during:** Task 1 (TDD RED phase)
- **Issue:** Test runner failed to bootstrap -- `applicationShouldTerminateAfterLastWindowClosed` returned true causing the app host to exit before tests could inject
- **Fix:** Added XCTestCase class detection to return false during test hosting; created shared xcscheme with test target
- **Files modified:** MDViewer/AppDelegate.swift, MDViewer.xcodeproj/xcshareddata/xcschemes/MDViewer.xcscheme
- **Verification:** All 12 tests pass via xcodebuild test
- **Committed in:** d2a4ae6 (Task 1 RED commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Test infrastructure fix was necessary to run any tests. No scope creep.

## Issues Encountered
None beyond the test infrastructure issue documented as a deviation.

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all functionality is fully wired.

## Next Phase Readiness
- N-chunk splitting produces multiple chunks that `WebContentView.injectRemainingChunks()` will inject progressively
- Plan 02-02 can now replace `evaluateJavaScript` with `callAsyncJavaScript` for typed chunk injection
- Memory-mapped read reduces peak heap for 10MB+ files

## Self-Check: PASSED
- All 4 key files exist
- All 3 task commits (d2a4ae6, 8c5ec22, c2bbedd) found in git history
- All 12 tests pass via xcodebuild test

---
*Phase: 02-large-file-memory-progressive-rendering*
*Completed: 2026-04-06*
