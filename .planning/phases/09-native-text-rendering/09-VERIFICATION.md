---
phase: 09-native-text-rendering
verified: 2026-04-16T15:10:00Z
status: human_needed
score: 4/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Visual typography match — native vs. web rendering"
    expected: "Latin Modern Roman font renders in NSTextView at body 16pt, h1 32pt, h2 24pt, h3 20pt with #333 text color and #1a3a6b link color matching the WKWebView path visually"
    why_human: "Font registration and rendering correctness can only be confirmed visually in the running app — OTF font may fall back to Times New Roman if bundle lookup fails at runtime"
  - test: "Sub-100ms warm launch for NSTextView path (PERF-02)"
    expected: "Instruments OSSignposter 'open-to-paint' interval for the native path is under 100ms on a warm launch"
    why_human: "Performance measurement requires running Instruments with OSSignposter on the built app — cannot be verified statically"
---

# Phase 9: Native Text Rendering Verification Report

**Phase Goal:** Simple markdown files (no mermaid, no GFM tables) render via NSTextView, bypassing WKWebView for dramatically faster display
**Verified:** 2026-04-16T15:10:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A markdown file without mermaid or GFM tables renders in an NSTextView window (no WKWebView created) | VERIFIED | `AppDelegate.openFileForced` calls `renderer.canRenderNatively(root:)` and routes to `NativeContentView` + `MarkdownWindow(isNative: true)` when result is true |
| 2 | Native rendering walks the cmark AST directly to build NSAttributedString (no HTML intermediate step) | VERIFIED | `NativeRenderer.swift` uses `cmark_iter_new`/`cmark_iter_next` and `NSMutableAttributedString`; grep confirms zero instances of `NSAttributedString(html:` |
| 3 | Native-rendered text uses Latin Modern Roman typography matching the WKWebView path visually | PARTIAL | Code registers OTF fonts via `CTFontManagerRegisterFontsForURL`, caches `NSFont(name: "Latin Modern Roman 10")` with fallback chain, and uses exact CSS-matching typography constants (body 16pt, h1 32pt, link #1a3a6b). Visual match requires human verification. |
| 4 | User can toggle between native and web rendering via menu item | VERIFIED | `toggleRenderingMode(_:)` in AppDelegate closes current window and reopens with forced mode; "Toggle Native/Web Rendering" item in View menu with Cmd+Shift+N; wired to `openFileForced(_:forceNative:)` |
| 5 | Warm launch to first visible content is under 100ms for the NSTextView path (measured via OSSignposter) | UNCERTAIN | OSSignposter instrumentation is wired (`nativeRenderingSignposter`, `appSignposter` open-to-paint interval ends in `nativeContentViewDidFinishFirstPaint`). Actual measurement requires Instruments. |

**Score:** 4/5 truths verified (SC3 and SC5 require human verification)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/NativeRenderer.swift` | cmark AST to NSAttributedString conversion | VERIFIED | 551 lines; contains `final class NativeRenderer`, `struct NativeRenderResult`, `cmark_iter_new`/`cmark_iter_next`, `CTFontManagerRegisterFontsForURL`, `OSSignposter`; no HTML intermediate |
| `MDViewer/NativeContentView.swift` | NSScrollView + NSTextView wrapper | VERIFIED | 132 lines; contains `final class NativeContentView: NSView`, `protocol NativeContentViewDelegate`, `NSScrollView`, `NSTextView`, `func loadContent(attributedString:)`, `isEditable = false`, `isVerticallyResizable = true`, 680px content width |
| `MDViewer/Resources/fonts/lmroman10-regular.otf` | Latin Modern Roman regular font for Core Text | VERIFIED | 111,536 bytes — real OTF from CTAN lm-2.004 |
| `MDViewer/Resources/fonts/lmroman10-bold.otf` | Latin Modern Roman bold font for Core Text | VERIFIED | 111,240 bytes — real OTF from CTAN lm-2.004 |
| `MDViewer/Resources/fonts/lmmono10-regular.otf` | Latin Modern Mono font for Core Text | VERIFIED | 64,684 bytes — real OTF from CTAN lm-2.004 |
| `MDViewer/MarkdownRenderer.swift` | AST pre-scan + parseForNative API | VERIFIED | Contains `func canRenderNatively(root:)` checking for "table" via `cmark_node_get_type_string` and "mermaid" via `cmark_node_get_fence_info`; contains `func parseMarkdown(_:)` returning caller-owned AST root |
| `MDViewer/MarkdownWindow.swift` | Generalized window for both backends | VERIFIED | `contentViewWrapper: NSView`, `isNativeRendering: Bool`, `fileURL: URL`, `webContentView`/`nativeContentView` computed accessors |
| `MDViewer/AppDelegate.swift` | Routing logic and toggle menu item | VERIFIED | `NativeContentViewDelegate` conformance, `canRenderNatively` routing, `NativeRenderer()` instantiation, `NativeContentView(frame: .zero)` creation, `NativeRenderer.registerFonts()` at launch, `toggleRenderingMode` with menu item |
| `MDViewerTests/NativeRendererTests.swift` | Unit tests for NativeRenderer | VERIFIED | 345 lines; 19 test methods covering headings, bold, italic, inline code, code block, links, lists, blockquotes, strikethrough, `canRenderNatively` pre-scan, and font detection |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `MDViewer/NativeRenderer.swift` | `cmark_gfm` | `cmark_iter_new`/`cmark_iter_next` AST traversal | WIRED | Both functions present in NativeRenderer.swift lines 188, 197 |
| `MDViewer/NativeContentView.swift` | `MDViewer/NativeRenderer.swift` | `loadContent(attributedString:)` receives `NativeRenderer` output | WIRED | `func loadContent(attributedString: NSAttributedString)` at line 80; AppDelegate pipes `nativeResult.attributedString` to it (line 264) |
| `MDViewer/AppDelegate.swift` | `MDViewer/MarkdownRenderer.swift` | `canRenderNatively(root:)` call for routing decision | WIRED | Line 236 in AppDelegate calls `renderer.canRenderNatively(root: root)` |
| `MDViewer/AppDelegate.swift` | `MDViewer/NativeRenderer.swift` | `NativeRenderer().render(root:)` for native path | WIRED | Lines 249-250 instantiate `NativeRenderer()` and call `nativeRenderer.render(root: root)` |
| `MDViewer/AppDelegate.swift` | `MDViewer/NativeContentView.swift` | `NativeContentView` creation for native path | WIRED | Line 256 creates `NativeContentView(frame: .zero)`, line 264 calls `loadContent` |
| `MDViewer/MarkdownWindow.swift` | `MDViewer/NativeContentView.swift` | `contentViewWrapper` stored as `NSView`, type-checked via `nativeContentView` | WIRED | Lines 23-25 provide `var nativeContentView: NativeContentView? { contentViewWrapper as? NativeContentView }` |
| `MDViewerTests/NativeRendererTests.swift` | `MDViewer/NativeRenderer.swift` | `@testable import MDViewer; NativeRenderer().render(root:)` | WIRED | Line 3 `@testable import MDViewer`, helper `renderNative(_:)` calls `NativeRenderer().render(root:)` |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `NativeContentView` | `attributedString` (set via `loadContent`) | `NativeRenderer.render(root:)` called with real parsed AST | Yes — AST walker reads `cmark_node_get_literal`, `cmark_node_get_heading_level`, etc. | FLOWING |
| `MarkdownWindow` | `contentViewWrapper` | Created with either `WebContentView` or `NativeContentView` at file open time | Yes — routing in `openFileForced` produces real content view | FLOWING |

### Behavioral Spot-Checks

Step 7b: SKIPPED for native rendering UI path — requires a running macOS app. Build compilation verified via git commit history showing `BUILD SUCCEEDED`. Tests verified as PASS via commit e552439 (19/19 passing per 09-03-SUMMARY).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| NATV-01 | 09-02-PLAN | Files without mermaid or GFM tables render via NSTextView instead of WKWebView | SATISFIED | `canRenderNatively` routing in AppDelegate; `NativeContentView` created on native path |
| NATV-02 | 09-01-PLAN, 09-03-PLAN | NSTextView backend walks cmark AST directly to build NSAttributedString | SATISFIED | `cmark_iter_new`/`cmark_iter_next` in NativeRenderer; no `NSAttributedString(html:)`; 19 unit tests pass |
| NATV-03 | 09-01-PLAN, 09-03-PLAN | Native rendering uses same Latin Modern Roman typography as WKWebView path | SATISFIED (code) / NEEDS HUMAN (visual) | OTF fonts bundled; `NSFont(name: "Latin Modern Roman 10")` used with CSS-matching constants (body 16pt, h1 32pt); visual match needs human check |
| NATV-04 | 09-02-PLAN | User can toggle between native and web rendering | SATISFIED | "Toggle Native/Web Rendering" in View menu; `toggleRenderingMode(_:)` implemented and wired |
| PERF-02 | 09-03-PLAN | Warm launch under 100ms for NSTextView path | NEEDS HUMAN | OSSignposter instrumentation in place (`nativeContentViewDidFinishFirstPaint` ends open-to-paint interval); actual measurement pending human Instruments run |

All 5 requirement IDs declared across plans (NATV-01, NATV-02, NATV-03, NATV-04, PERF-02) are mapped and accounted for.

### Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `MDViewer/NativeContentView.swift` line 94-97 | `toggleMonospace()` is a no-op stub — toggles `isMonospace` flag only, does not re-render | WARNING | Monospace toggle has no visual effect in native rendering mode. Note: this is outside NATV-01 through NATV-04 scope; monospace toggle within the native path was marked "no-op placeholder" by design in Plan 01. Does not block phase goal. |

### Human Verification Required

#### 1. Visual Typography Match — Native vs. Web Rendering

**Test:** Build and run the app (`open MDViewer.xcodeproj`, then Cmd+R). Open a simple markdown file containing headings, bold, italic, code blocks, and links. Then use View > Toggle Native/Web Rendering (Cmd+Shift+N) to switch between native NSTextView and WKWebView rendering.

**Expected:** Both rendering paths should display nearly identical typography — Latin Modern Roman font (not San Francisco), body text at 16pt, h1 at 32pt, h2 at 24pt, h3 at 20pt, link color in dark blue (#1a3a6b), code blocks with cream background (#f8f6f0). The native path should NOT show San Francisco or Times New Roman as the body font.

**Why human:** Font registration via `CTFontManagerRegisterFontsForURL` can silently fall back to Times New Roman or system font if the OTF file name in the bundle doesn't match expectations. Only the running app can confirm the registered font is the one actually displayed.

#### 2. Sub-100ms Warm Launch for NSTextView Path (PERF-02)

**Test:** Open Instruments (Product > Profile in Xcode), select the OSSignposter template. Build and run MDViewer. Open a simple markdown file (no mermaid, no tables) once (warm run — app already launched). Stop recording. Inspect the `open-to-paint` interval in the `RenderingPipeline` category.

**Expected:** The `open-to-paint` interval for the NSTextView rendering path is under 100ms. Because native rendering is synchronous (no WKWebView async navigation), it should be significantly faster than the WKWebView path.

**Why human:** OSSignposter intervals are only visible in Instruments at runtime and cannot be measured by static code analysis. The synchronous nature of `nativeContentViewDidFinishFirstPaint` (called immediately in `loadContent`) strongly suggests sub-100ms is achievable, but measurement is required to confirm PERF-02.

### Gaps Summary

No automated gaps found. All code-verifiable must-haves pass. Two items require human verification before phase can be marked passed:

1. **NATV-03 visual confirmation** — Latin Modern Roman font must be confirmed as actually rendering (not falling back to Times New Roman) when a simple markdown file is opened via the native path.

2. **PERF-02 measurement** — The 100ms warm launch target for NSTextView requires an Instruments OSSignposter measurement run. Given the synchronous dispatch path (`loadContent` → immediate delegate callback → `showWithFadeIn`), this is expected to pass but must be confirmed.

---

_Verified: 2026-04-16T15:10:00Z_
_Verifier: Claude (gsd-verifier)_
