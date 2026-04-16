---
phase: 09-native-text-rendering
plan: 01
subsystem: rendering
tags: [native-rendering, nsattributedstring, cmark-ast, core-text, fonts]
dependency_graph:
  requires: []
  provides: [NativeRenderer, NativeRenderResult, NativeContentView, NativeContentViewDelegate]
  affects: []
tech_stack:
  added: [CTFontManagerRegisterFontsForURL, NSTextView, NSMutableAttributedString, cmark_iter]
  patterns: [ast-visitor-style-stack, font-caching, delegate-first-paint]
key_files:
  created:
    - MDViewer/NativeRenderer.swift
    - MDViewer/NativeContentView.swift
    - MDViewer/Resources/fonts/lmroman10-regular.otf
    - MDViewer/Resources/fonts/lmroman10-bold.otf
    - MDViewer/Resources/fonts/lmmono10-regular.otf
  modified:
    - MDViewer.xcodeproj/project.pbxproj
decisions:
  - "Used UnsafeMutablePointer<cmark_node> instead of OpaquePointer for render() API -- matches actual cmark C types"
  - "NSFontDescriptor.withSymbolicTraits returns non-optional on macOS -- removed conditional binding"
  - "Downloaded OTF fonts from CTAN lm.zip (version 2.004) -- real fonts, not placeholders"
metrics:
  duration: 352s
  completed: 2026-04-16T12:34:11Z
  tasks_completed: 2
  tasks_total: 2
  files_created: 5
  files_modified: 1
---

# Phase 09 Plan 01: NativeRenderer + NativeContentView Summary

cmark AST-to-NSAttributedString walker with style-stack pattern, plus NSScrollView+NSTextView wrapper with 680px content width and Latin Modern OTF fonts from CTAN

## What Was Built

### NativeRenderer (551 lines)
- Walks cmark AST via `cmark_iter_new`/`cmark_iter_next` to build `NSAttributedString` directly -- no HTML intermediate step
- Style stack pattern: pushes style state on ENTER events, pops on EXIT, applies accumulated attributes to leaf text nodes
- Handles all core cmark node types: document, heading (h1-h6), paragraph, blockquote, list (ordered/unordered), item, code block, code inline, emphasis, strong, link, image, thematic break, HTML block/inline, softbreak, linebreak
- Extension node types (strikethrough, tasklist) handled via `cmark_node_get_type_string()` string comparison since they are not exposed in the modulemap
- Typography constants match template.html CSS exactly: body 16pt, h1 32pt, h2 24pt, h3 20pt, code 14.4pt, code block 13.6pt, link color #1a3a6b, text color #333, heading color #1a1a1a
- Font registration via `CTFontManagerRegisterFontsForURL` with `.process` scope, guarded by static `fontsRegistered` flag
- All NSFont variants cached at init time (body, bold, italic, bold-italic, code, code-block, h1-h6) -- no font creation per-node
- Fallback chain: Latin Modern Roman 10 -> Times New Roman -> system font; Latin Modern Mono 10 -> Menlo -> monospaced system font
- OSSignposter instrumentation wrapping the full render method
- Memory safe: `defer { cmark_iter_free(iter) }`, root pointer is borrowed (not freed)

### NativeContentView (132 lines)
- NSView subclass wrapping NSScrollView + NSTextView for native markdown display
- NativeContentViewDelegate protocol with `nativeContentViewDidFinishFirstPaint` -- mirrors WebContentViewDelegate pattern
- Fixed 680px text container width with `widthTracksTextView = false`
- Dynamic horizontal centering via `textContainerInset` recalculated on `layout()`
- Synchronous first-paint delegate callback (no WKWebView async delay)
- `loadContent(attributedString:)` sets text storage and fires delegate immediately
- Print support via `NSPrintOperation(view: textView)` -- simpler than WKWebView PDF workaround
- Monospace toggle placeholder (stores `cachedAttributedString` for future re-render)
- Follows project conventions: `final class`, `weak var delegate`, `fatalError("init(coder:)")`, `#if DEBUG` deinit logging

### OTF Font Files
- Downloaded from CTAN (lm-2.004/fonts/opentype/public/lm/)
- lmroman10-regular.otf (111KB), lmroman10-bold.otf (111KB), lmmono10-regular.otf (65KB)
- Placed alongside existing WOFF2 files (WOFF2 retained for WKWebView path)

## Task Completion

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Acquire OTF fonts + NativeRenderer | 3649363 | NativeRenderer.swift, 3 OTF fonts |
| 2 | Create NativeContentView | 9a87c14 | NativeContentView.swift |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed pointer type mismatch**
- **Found during:** Task 1
- **Issue:** Plan specified `OpaquePointer` for the render() API, but cmark C functions use typed `UnsafeMutablePointer<cmark_node>` in Swift
- **Fix:** Changed render() signature to `func render(root: UnsafeMutablePointer<cmark_node>) -> NativeRenderResult`
- **Files modified:** MDViewer/NativeRenderer.swift

**2. [Rule 1 - Bug] Fixed NSFontDescriptor.withSymbolicTraits conditional binding**
- **Found during:** Task 1
- **Issue:** `NSFontDescriptor.withSymbolicTraits(_:)` returns non-optional `NSFontDescriptor` on macOS (unlike UIKit's optional return). Using `if let` caused compile errors.
- **Fix:** Assigned directly to `let` instead of `if let` conditional binding
- **Files modified:** MDViewer/NativeRenderer.swift

## Known Stubs

None -- all functionality specified in the plan is implemented. The monospace toggle in NativeContentView is intentionally a placeholder per the plan ("no-op placeholder that will be wired when integration happens in Plan 02").

## Verification

1. Project builds cleanly: `xcodebuild build -scheme MDViewer` -- BUILD SUCCEEDED
2. NativeRenderer.swift contains `cmark_iter_new` and `cmark_iter_next` (AST walking)
3. NativeRenderer.swift contains `NSMutableAttributedString` (direct building)
4. NativeRenderer.swift does NOT contain `NSAttributedString(html:` (no HTML intermediate)
5. NativeRenderer.swift contains `CTFontManagerRegisterFontsForURL` (font registration)
6. NativeRenderer.swift contains `OSSignposter` instrumentation
7. Three OTF font files exist and are non-zero size
8. NativeContentView.swift contains NSScrollView + NSTextView with 680px width

## Self-Check: PASSED

All 5 created files verified on disk. Both commit hashes (3649363, 9a87c14) verified in git log.
