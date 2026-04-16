---
phase: 07-wkwebview-pool
fixed_at: 2026-04-16T00:00:00Z
review_path: .planning/phases/07-wkwebview-pool/07-REVIEW.md
iteration: 1
findings_in_scope: 4
fixed: 4
skipped: 0
status: all_fixed
---

# Phase 07: Code Review Fix Report

**Fixed at:** 2026-04-16
**Source review:** .planning/phases/07-wkwebview-pool/07-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 4
- Fixed: 4
- Skipped: 0

## Fixed Issues

### WR-01: Signpost interval leaks when `self` is deallocated during chunk injection

**Files modified:** `MDViewer/WebContentView.swift`
**Commit:** ad7d585
**Applied fix:** Added a `guard let self else` block in the `DispatchQueue.main.asyncAfter` closure within `injectRemainingChunks`. When `self` is nil (window closed before chunk fires), the last scheduled slot now ends the signpost interval before returning, preventing a process-lifetime leak.

### WR-02: Active-window web-process crash is silent

**Files modified:** `MDViewer/AppDelegate.swift`
**Commit:** 2c637d5
**Applied fix:** After dequeue in `displayResult`, the content view's navigation delegate is now set to `self` (AppDelegate). Added `import WebKit` and a `WKNavigationDelegate` extension on `AppDelegate` that implements `webViewWebContentProcessDidTerminate` -- it finds the owning window, shows a critical alert to the user, and closes the window.

### WR-03: `ensureTemplateLoaded()` unconditionally rebuilds the menu bar

**Files modified:** `MDViewer/AppDelegate.swift`
**Commit:** 645db29
**Applied fix:** Removed the `setupMenu()` call from `ensureTemplateLoaded()`. Menu setup is already handled at launch in `applicationDidFinishLaunching`. The method now uses an early `guard` return and only calls `loadTemplate()`.

### WR-04: `hasProcessedFirstPaint` is never reset between document loads on a reused pool view

**Files modified:** `MDViewer/WebContentView.swift`
**Commit:** 6fe3b92
**Applied fix:** Added `self.hasProcessedFirstPaint = false` at the top of `loadContent(page:remainingChunks:hasMermaid:)` to reset per-load transient state when a pooled view is reused.

## Skipped Issues

None -- all in-scope findings were fixed.

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
