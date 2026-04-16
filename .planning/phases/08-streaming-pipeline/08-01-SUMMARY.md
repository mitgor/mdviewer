---
phase: 08-streaming-pipeline
plan: 01
subsystem: rendering
tags: [cmark-gfm, streaming, buffer-reuse, c-callback, osSignposter]

# Dependency graph
requires:
  - phase: 06-vendored-cmark
    provides: cmark_render_html_chunked C callback API with mermaid detection
provides:
  - StreamingRenderContext class for C callback streaming
  - renderStreaming method with onFirstChunk/onComplete callbacks
  - assembleFirstPage buffer-reuse method (STRM-02)
  - File-based renderStreaming with OSSignposter instrumentation
affects: [08-02-streaming-pipeline, performance-measurement]

# Tech tracking
tech-stack:
  added: []
  patterns: [streaming-callback-dispatch, buffer-reuse-removeAll-keepingCapacity]

key-files:
  created: []
  modified:
    - MDViewer/MarkdownRenderer.swift
    - MDViewerTests/MarkdownRendererTests.swift

key-decisions:
  - "assemblyBuffer lives on MarkdownRenderer instance with thread-safety documented (not enforced) -- matches existing ChunkedRenderContext pattern"
  - "assembleFirstPage uses [UInt8] with removeAll(keepingCapacity: true) for zero-alloc template assembly"
  - "hasMermaid delivered via onComplete (not onFirstChunk) to avoid race with later-chunk mermaid blocks"

patterns-established:
  - "StreamingRenderContext: C callback context with firstChunkSent gate and onFirstChunk closure"
  - "Buffer reuse: removeAll(keepingCapacity: true) on [UInt8] array for template concatenation"

requirements-completed: [STRM-01, STRM-02]

# Metrics
duration: 3min
completed: 2026-04-16
---

# Phase 8 Plan 1: Streaming Render Pipeline Summary

**Streaming render method with C callback first-chunk dispatch and buffer-reuse template assembly using removeAll(keepingCapacity: true)**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-16T11:26:57Z
- **Completed:** 2026-04-16T11:29:55Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- StreamingRenderContext class that fires onFirstChunk on first C callback invocation, accumulates remaining chunks
- renderStreaming(markdown:template:onFirstChunk:onComplete:) method for streaming render with callback-based delivery
- renderStreaming(fileURL:template:onFirstChunk:onComplete:) with OSSignposter instrumentation (parse-feed, stream-first-chunk intervals)
- assembleFirstPage buffer-reuse method eliminating String concatenation for template assembly (STRM-02)
- 8 new tests covering streaming, buffer reuse, mermaid detection, file-based streaming, and single-chunk degradation
- All 22 tests pass (14 existing + 8 new)

## Task Commits

Each task was committed atomically:

1. **Task 1: StreamingRenderContext, renderStreaming, buffer-reuse assembly** - `d38c404` (test: RED), `9ad226e` (feat: GREEN)
2. **Task 2: Unit tests for streaming render and buffer reuse** - `bf93cba` (test)

_Note: Task 1 used TDD (test -> feat commits)_

## Files Created/Modified
- `MDViewer/MarkdownRenderer.swift` - Added StreamingRenderContext, assemblyBuffer, assembleFirstPage, renderStreaming (string + file overloads)
- `MDViewerTests/MarkdownRendererTests.swift` - 8 new tests for streaming render pipeline

## Decisions Made
- assemblyBuffer on MarkdownRenderer instance with documented (not enforced) thread-safety -- matches existing pattern where callers serialize renders
- hasMermaid delivered via onComplete callback, not onFirstChunk -- avoids Pitfall 1 (mermaid in later chunks)
- assembleFirstPage is internal access (not private) to enable direct unit testing
- Existing renderFullPage methods preserved unchanged for backward compatibility

## Deviations from Plan

None - plan executed exactly as written.

## TDD Gate Compliance

- RED gate: `d38c404` (test commit with 5 failing tests -- compilation errors confirm methods don't exist)
- GREEN gate: `9ad226e` (feat commit -- all 19 tests pass after implementation)
- REFACTOR gate: skipped (code follows established patterns, no cleanup needed)

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- renderStreaming API ready for Plan 02 to wire into AppDelegate/WebContentView
- onFirstChunk callback designed for DispatchQueue.main.async dispatch in AppDelegate
- onComplete delivers remaining chunks + hasMermaid for WebContentView.setRemainingChunks

---
*Phase: 08-streaming-pipeline*
*Completed: 2026-04-16*
