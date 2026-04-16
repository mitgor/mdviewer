---
phase: 09-native-text-rendering
plan: 02
subsystem: rendering
tags: [native-rendering, routing, ast-prescan, toggle, menu]
dependency_graph:
  requires: [NativeRenderer, NativeContentView, NativeContentViewDelegate, NativeRenderResult]
  provides: [canRenderNatively, parseMarkdown, openFileForced, toggleRenderingMode]
  affects: [AppDelegate, MarkdownWindow, MarkdownRenderer]
tech_stack:
  added: []
  patterns: [ast-prescan, forced-rendering-override, type-checked-accessors]
key_files:
  created: []
  modified:
    - MDViewer/MarkdownRenderer.swift
    - MDViewer/MarkdownWindow.swift
    - MDViewer/AppDelegate.swift
decisions:
  - "Used UnsafeMutablePointer<cmark_node> for parseMarkdown/canRenderNatively APIs to match cmark C types (consistent with NativeRenderer from Plan 01)"
  - "Implemented openFileForced with optional Bool (nil=auto, true=native, false=web) rather than separate methods for cleaner toggle logic"
  - "Parse AST twice on native path (once for detection, once for rendering) to avoid threading complexity of passing root across queues -- negligible cost for typical files"
  - "Toggle closes current window and reopens with forced mode rather than in-place swap -- simpler and avoids partial state issues"
metrics:
  duration: 223s
  completed: 2026-04-16T12:41:04Z
  tasks_completed: 2
  tasks_total: 2
  files_created: 0
  files_modified: 3
---

# Phase 09 Plan 02: Native Rendering Integration Summary

AST pre-scan routing simple markdown to NSTextView, with Cmd+Shift+N toggle between native and web rendering paths

## What Was Built

### MarkdownRenderer Extensions
- `parseMarkdown(_:) -> UnsafeMutablePointer<cmark_node>?` -- exposes cmark AST parsing as a separate step with caller-owned root pointer; creates parser with CMARK_OPT_SMART | CMARK_OPT_UNSAFE, attaches all four GFM extensions, returns root without freeing
- `canRenderNatively(root:) -> Bool` -- top-level AST scan checking for GFM tables (via `cmark_node_get_type_string` == "table") and mermaid code blocks (via `cmark_node_get_fence_info` == "mermaid"); only traverses first-level children using `cmark_node_first_child`/`cmark_node_next`

### MarkdownWindow Generalization
- `contentViewWrapper` changed from `WebContentView` to `NSView` -- supports both rendering backends
- `isNativeRendering: Bool` flag tracks which path this window uses
- `fileURL: URL` retained for toggle re-render (was previously only used in init)
- `webContentView` / `nativeContentView` computed properties for type-checked access
- Init now accepts `(fileURL:contentView:isNative:)` -- all existing behavior preserved (frame autosave, cascading, fade-in, high refresh rate)

### AppDelegate Routing
- `openFile(_:)` now calls `openFileForced(_:forceNative:)` with `nil` (auto-detect)
- Auto-detect path: reads file, parses AST, runs `canRenderNatively`, frees root, then dispatches to appropriate backend
- Native path: creates `NativeRenderer`, renders AST to `NSAttributedString`, creates `NativeContentView`, sets delegate, fires `loadContent`
- Web path: preserved existing streaming render pipeline with `onFirstChunk`/`onComplete` callbacks, WebViewPool, and navigation delegate
- `pendingFileOpens` counter preserved on both paths for correct app termination behavior
- `observeWindowClose(_:)` extracted as shared helper (DRY)

### Menu and Actions
- "Toggle Native/Web Rendering" added to View menu with Cmd+Shift+N shortcut
- `toggleRenderingMode(_:)` closes current window and reopens with forced opposite mode
- `toggleMonospace`, `printDocument`, `exportPDF` all updated to handle both view types via type-checked accessors
- PDF export shows informational alert in native mode (not supported without WKWebView)

### Delegate Conformance
- `NativeContentViewDelegate` added to AppDelegate -- handles launch-to-paint signpost, open-to-paint signpost, and `showWithFadeIn()` trigger
- `NativeRenderer.registerFonts()` called in `applicationDidFinishLaunching` before `NSApp.activate`

## Task Completion

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | AST pre-scan + generalize MarkdownWindow | 1b709c6 | MarkdownRenderer.swift, MarkdownWindow.swift, AppDelegate.swift |
| 2 | Wire routing + toggle menu in AppDelegate | b735c6a | AppDelegate.swift |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Used UnsafeMutablePointer<cmark_node> instead of OpaquePointer**
- **Found during:** Task 1
- **Issue:** Plan specified `OpaquePointer` for `canRenderNatively(root:)` and `parseMarkdown` return type, but cmark C functions use typed `UnsafeMutablePointer<cmark_node>` in Swift (consistent with Plan 01 deviation)
- **Fix:** Changed signatures to use `UnsafeMutablePointer<cmark_node>` throughout
- **Files modified:** MDViewer/MarkdownRenderer.swift

**2. [Rule 1 - Bug] Updated AppDelegate call sites for MarkdownWindow init change**
- **Found during:** Task 1
- **Issue:** Changing `contentViewWrapper` from `WebContentView` to `NSView` and adding `isNative:` parameter broke existing AppDelegate call sites (toggleMonospace, print, exportPDF, displayResult, crash handler)
- **Fix:** Added temporary casts in Task 1 for compilation, replaced with proper type-checked accessors in Task 2
- **Files modified:** MDViewer/AppDelegate.swift

**3. [Rule 3 - Blocking] Added cmark_gfm import to AppDelegate**
- **Found during:** Task 2
- **Issue:** AppDelegate now calls `cmark_node_free(root)` directly, requiring `import cmark_gfm`
- **Fix:** Added `import cmark_gfm` to AppDelegate.swift
- **Files modified:** MDViewer/AppDelegate.swift

## Known Stubs

None -- all functionality specified in the plan is implemented.

## Verification

1. Project builds cleanly: `xcodebuild build -scheme MDViewer` -- BUILD SUCCEEDED
2. MarkdownRenderer.swift contains `canRenderNatively(root:)` with table and mermaid checks
3. MarkdownRenderer.swift contains `parseMarkdown(_:)` returning caller-owned AST root
4. MarkdownWindow.swift `contentViewWrapper` is typed `NSView` with `isNativeRendering` flag
5. AppDelegate.swift contains `NativeContentViewDelegate` conformance
6. AppDelegate.swift contains `NativeRenderer.registerFonts()` in applicationDidFinishLaunching
7. AppDelegate.swift contains "Toggle Native/Web Rendering" menu item
8. AppDelegate.swift routes via `canRenderNatively` in auto-detect path

## Self-Check: PASSED

All 4 files verified on disk. Both commit hashes (1b709c6, b735c6a) verified in git log.
