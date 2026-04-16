---
phase: 07-wkwebview-pool
plan: 02
one_liner: "AppDelegate pool integration replacing single preWarmedContentView, with 5 unit tests for pool behavior"
subsystem: rendering-pipeline
tags: [pool, wkwebview, performance, integration, tests]
dependency_graph:
  requires: [WebViewPool, WebContentView-pool-support]
  provides: [pool-integrated-app, pool-tests]
  affects: [AppDelegate-displayResult, open-to-paint-signpost]
tech_stack:
  added: []
  patterns: [object-pool-consumer, nil-coalescing-fallback]
key_files:
  created:
    - MDViewerTests/WebViewPoolTests.swift
  modified:
    - MDViewer/AppDelegate.swift
    - MDViewer/WebViewPool.swift
    - MDViewer.xcodeproj/project.pbxproj
decisions:
  - "Pool capacity of 2 matches typical multi-file usage pattern"
  - "Nil-coalescing fallback ensures file open never fails even if pool exhausted"
  - "applicationWillTerminate left as empty stub (pool drains via ARC on AppDelegate dealloc)"
metrics:
  duration: "170s"
  completed: "2026-04-16T09:29:12Z"
  tasks_completed: 3
  tasks_total: 3
  files_created: 1
  files_modified: 3
---

# Phase 07 Plan 02: WebViewPool Integration Summary

AppDelegate pool integration replacing single preWarmedContentView, with 5 unit tests for pool behavior.

## What Was Done

### Task 1: Replace preWarmedContentView with WebViewPool in AppDelegate
Made four targeted changes to AppDelegate.swift:
- Replaced `private var preWarmedContentView: WebContentView?` with `private let webViewPool = WebViewPool(capacity: 2)`
- Removed manual `preWarmedContentView = WebContentView(frame: .zero)` from applicationDidFinishLaunching
- Updated applicationWillTerminate to empty stub (pool drains automatically via ARC)
- Replaced 5-line if/else dequeue logic with single line: `webViewPool.dequeue() ?? WebContentView(frame: .zero)`
- Existing `open-to-paint` signpost automatically measures pool improvement (no changes needed)

### Task 2: Add WebViewPool unit tests
Created `MDViewerTests/WebViewPoolTests.swift` with 5 tests:
- `testDequeueReturnsViewWhenPoolHasCapacity` -- verifies pool returns a view
- `testDequeueReturnsNilWhenPoolExhausted` -- verifies nil when empty
- `testDequeueReturnsDifferentInstances` -- verifies distinct instances via identity check
- `testPoolReplenishesAfterDequeue` -- verifies async replenishment via expectation
- `testDiscardTriggersReplenishment` -- verifies crash recovery replenishment

### Task 3: Build and verify full integration
Full build and all 20 tests pass (14 MarkdownRendererTests + 5 WebViewPoolTests + 1 MDViewerTests). Zero references to `preWarmedContentView` remain in codebase.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed super.init ordering in WebViewPool.init**
- **Found during:** Task 2 (build failure)
- **Issue:** WebViewPool.init(capacity:) called `createView()` (instance method) before `super.init()`, violating Swift initialization rules. This was a latent bug from Plan 01 that only surfaced when building with XcodeGen-regenerated project.
- **Fix:** Added `super.init()` call before the pool-filling loop
- **Files modified:** MDViewer/WebViewPool.swift
- **Commit:** 22e0d3b

**2. [Rule 3 - Blocking] Regenerated project.pbxproj via XcodeGen**
- **Found during:** Task 2 (build failure)
- **Issue:** Pre-generated project.pbxproj didn't include WebViewPool.swift (created in Plan 01 worktree, merged after pbxproj was generated)
- **Fix:** Ran `xcodegen generate` to regenerate project including all current source files
- **Files modified:** MDViewer.xcodeproj/project.pbxproj
- **Commit:** 22e0d3b

## Verification

- BUILD SUCCEEDED (full project)
- 20/20 tests pass (all suites)
- `grep -rn "preWarmedContentView" MDViewer/` returns 0 matches
- `grep -c "webViewPool" MDViewer/AppDelegate.swift` returns 2 (property + dequeue)
- `open-to-paint` signpost unchanged on line 142

## Commits

| Task | Commit | Message |
|------|--------|---------|
| 1 | db0d9da | feat(07-02): replace preWarmedContentView with WebViewPool in AppDelegate |
| 2 | 22e0d3b | test(07-02): add WebViewPool unit tests and fix super.init ordering |

## Self-Check: PASSED
