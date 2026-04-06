# Feature Landscape: Performance Optimization for macOS Markdown Viewer

**Domain:** Native macOS document viewer (AppKit + WKWebView + cmark-gfm)
**Researched:** 2026-04-03
**Research mode:** Ecosystem — what fast document viewers implement

---

## Context: Current State

MDViewer already has a meaningful performance foundation:
- Background thread markdown parsing (cmark-gfm, C library, <10ms for typical files)
- Pre-split template (no string scanning at render time)
- Cached regex patterns
- 2-chunk progressive rendering (first 50 block elements, then remainder)
- `firstPaint` JS message back-channel to gate chunk injection on actual DOM readiness

Known bottlenecks from codebase audit:
- File read is synchronous (`String(contentsOf:)`) on the background thread — blocks for large files
- Chunking always produces at most 2 chunks; second chunk can be multi-megabyte
- Mermaid JS (3 MB) injected via `evaluateJavaScript` string bridge on every diagram window
- Mermaid JS read from disk synchronously on first use (main thread)
- `WKUserContentController` retain cycle — `WebContentView` never released
- `injectRemainingChunks` builds JS by manual string construction (escaping gaps)
- Window frame persistence broken (`loadSavedFrame` always returns nil)

---

## Table Stakes

Features users expect from any "fast" document viewer. Missing or broken = product feels broken.

| Feature | Why Expected | Complexity | Current Status |
|---------|--------------|------------|----------------|
| Sub-100ms to first visible content | Finder quick-look pattern sets this bar | Medium | ~150-200ms; WKWebView cold init is the bottleneck |
| No jank during scroll | Smooth scroll is a macOS system expectation | Low | WKWebView handles this; no action needed |
| Memory release on window close | Baseline hygiene; multiple windows must not accumulate | Medium | Broken — retain cycle in `WKUserContentController` means `WebContentView` never deallocates |
| Correct window position restore | Users reposition windows; position should persist | Low | Broken — `loadSavedFrame` always returns nil |
| No main-thread stall on open | File open must not freeze the app | Low | Background parsing already done; file read is on bg thread |
| Reasonable memory for small files | <50 MB RSS for a 100 KB markdown file | Low | Currently acceptable; per-window `WKWebView` is ~30-40 MB baseline |
| Opens files 10 MB+ without OOM | Large tech docs, generated output | High | Not implemented — `String(contentsOf:)` loads entire file into memory |
| Correct rendering at all sizes | Content must not clip or overflow | Low | Already correct |

---

## Differentiators

Features that make this viewer distinctly fast or capable, beyond baseline expectations.

### 1. True N-Chunk Progressive Rendering

**What:** Split HTML output into N equal-sized chunks (configurable, e.g. 200 block elements per chunk) and inject them via staggered `setTimeout` calls, spreading parse work across multiple animation frames.

**Why it matters:** The current 2-chunk split means a 5,000-element document still hits the JS engine with a ~4 MB string in one `evaluateJavaScript` call. That call blocks the render thread. Spreading into 10-20 chunks at 16 ms intervals keeps the UI frame rate at 60 fps throughout load.

**Implementation path:** Modify `MarkdownRenderer.chunkHTML` to split at every N-th block tag (not just the 50th). The JS side already supports arrays of chunks via the `i * 16` stagger pattern — no JS changes needed.

**Confidence:** HIGH — the JS infrastructure already exists; this is purely a Swift-side chunking fix.

---

### 2. Memory-Mapped File Reading for Large Files

**What:** Use `Data(contentsOf: url, options: .mappedIfSafe)` instead of `String(contentsOf:)`. The OS maps the file into the virtual address space without loading it into RAM upfront. Pages are faulted in on demand.

**Why it matters:** A 10 MB markdown file loaded with `String(contentsOf:)` allocates 10 MB of RAM immediately plus the intermediate UTF-8 buffer. With `.mappedIfSafe`, only the pages actually touched by the cmark-gfm parser are loaded, and the OS can reclaim pages after the parser passes them.

**Limits:** `.mappedIfSafe` only activates on fixed-volume files (not network drives, not removable media). Falls back to normal read automatically, so it is safe to use unconditionally.

**Confidence:** HIGH — Apple documents this behavior explicitly. `Data(contentsOf:options:.mappedIfSafe)` is the recommended pattern in Apple's File Management guide.

---

### 3. Mermaid JS via `<script src>` Tag Instead of `evaluateJavaScript`

**What:** Add `<script src="mermaid.min.js"></script>` to `template.html` rather than injecting the 3 MB string through the Swift/JS bridge. WKWebView's `baseURL` is already set to `Bundle.main.resourceURL`, so the relative path resolves automatically.

**Why it matters:** The `evaluateJavaScript` bridge serializes the string through IPC between the Swift process and the WKWebView renderer process. Passing 3 MB strings this way is expensive. Loading from a `<script src>` URL lets WebKit's resource loader handle it natively — no IPC serialization, and WebKit can cache the parsed bytecode across page loads.

**Tradeoff:** The script loads eagerly on every page, even those without Mermaid. Mitigation: gate initialization (`window.initMermaid()`) on the presence of `.mermaid-placeholder` elements, which already happens.

**Confidence:** HIGH — the baseURL mechanism is already in use for fonts. This is the same pattern.

---

### 4. `callAsyncJavaScript` with Typed Arguments for Chunk Injection

**What:** Replace the manual JS string builder in `injectRemainingChunks` with `callAsyncJavaScript(_:arguments:in:in:completionHandler:)`, passing the chunks array as a typed Swift `[String: Any]` argument dict. WebKit handles serialization and escaping correctly.

**Why it matters:** The current manual escaper handles `\`, `` ` ``, and `$` but misses null bytes and Unicode surrogates in malformed markdown output. `callAsyncJavaScript` uses `JSValue` serialization — equivalent to `JSON.stringify` — which is correct for all Unicode.

**Performance benefit:** Minor improvement for normal files. Significant safety improvement for pathological inputs.

**Confidence:** HIGH — `callAsyncJavaScript` is available macOS 10.15+ and documented on Apple Developer.

---

### 5. WKWebView Warm-Up at App Launch

**What:** Allocate a `WKWebView` instance during `applicationDidFinishLaunching` and discard it after a short delay. The first WKWebView initialization triggers WebKit's process pool creation, which takes 30-80 ms. Subsequent WKWebView instances reuse the already-running WebKit process.

**Why it matters:** On a cold launch, the first `WKWebView(frame:configuration:)` call in `displayResult` happens after the file is parsed but before the window appears. That 30-80 ms is added to the user-visible latency. Warming the pool during app init moves this cost to the pre-launch phase.

**Implementation path:** In `applicationDidFinishLaunching`, after `loadTemplate()`, create a throwaway `WKWebView` on the main thread. Schedule its removal with a 200 ms `DispatchQueue.main.asyncAfter`. This overlaps with the background parsing work.

**Confidence:** MEDIUM — The WebViewWarmUper pattern is documented in open-source libraries and developer forum threads. The actual savings depend on OS WebKit process reuse behavior, which Apple does not fully document. The technique is low-risk (worst case: wasted 30-80 ms at launch that the user never sees).

---

### 6. Correct `WKUserContentController` Weak Handler (Fix Retain Cycle)

**What:** Replace `contentController.add(self, name: "firstPaint")` with a weak-proxy wrapper conforming to `WKScriptMessageHandler`. The proxy holds a weak reference to `WebContentView` and forwards messages.

**Why it matters:** As documented in CONCERNS.md, the current code creates a retain cycle: `WKUserContentController` strongly retains its message handlers, so `WebContentView` (and its embedded `WKWebView`) is never deallocated when a window closes. Each closed window continues to hold ~30-40 MB of WebKit process memory. Opening and closing 10 documents leaks 300-400 MB.

**Confidence:** HIGH — The retain cycle is fully documented by Apple and in community post-mortems. The weak-proxy pattern is the canonical fix.

---

### 7. Proper Window Frame Persistence

**What:** Fix `loadSavedFrame()` so that `setFrameAutosaveName` actually restores position. The simplest path: delete `loadSavedFrame()` and the manual `setFrame` call, and rely on AppKit's automatic frame restoration that triggers when `setFrameAutosaveName` is set before `makeKeyAndOrderFront`.

**Why it matters:** Users open the same file repeatedly. The window appearing at a remembered position is a baseline macOS app behavior — any deviation feels like a bug.

**Per-file key conflict:** The static `frameSaveKey = "MDViewerWindowFrame"` means multi-window position conflicts. Acceptable behavior for a viewer-not-editor: last-closed window wins. Document this. Do not build per-file hashing unless user feedback demands it.

**Confidence:** HIGH — AppKit frame autosave is well-documented behavior.

---

### 8. Streaming / Chunked File Read for 10 MB+ Files

**What:** Read large markdown files in chunks using `FileHandle` or `DispatchIO` rather than loading the entire file at once. Feed chunks to `cmark_parser_feed` incrementally. This is the correct API — `cmark_parser_feed` is specifically designed for incremental input.

**Why it matters:** `cmark_parser_feed` accepts bytes incrementally and `cmark_parser_finish` finalizes the parse. The parser already handles partial input correctly. This is the designed usage pattern from the cmark-gfm README.

**Complexity:** Medium-high. The chunked read must be coordinated with the background dispatch queue. Memory-mapped reading (Feature 2) is the simpler first step and handles most real-world files. True streaming matters for files >50 MB.

**Confidence:** HIGH for API availability (cmark_parser_feed is the public API). MEDIUM for whether most users need this vs. memory mapping alone.

---

### 9. `suppressesIncrementalRendering = false` (Explicit, Not Default)

**What:** Verify `WKWebViewConfiguration.suppressesIncrementalRendering` is false (the default). If it is not explicitly set, confirm the default remains false in the target OS range (macOS 13+).

**Why it matters:** If this property were inadvertently set to `true`, WKWebView would buffer all content before painting, eliminating the first-chunk / firstPaint benefit entirely. Currently unset in code — behavior relies on an undocumented default.

**Action:** Add `config.suppressesIncrementalRendering = false` explicitly in `WebContentView.init`. This costs nothing and makes the intent explicit.

**Confidence:** HIGH — Property documented on Apple Developer. Default is false.

---

## Anti-Features

Features that hurt performance or create maintenance debt — explicitly avoid.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Loading entire large file into a single Swift String before parsing | Allocates full file size in RAM immediately, then allocates HTML output (2-3x file size total) | Memory-mapped `Data` + chunked `cmark_parser_feed` |
| `evaluateJavaScript` with multi-megabyte string payloads | IPC serialization cost; JS engine blocks render thread during parse | N-chunk splitting + `callAsyncJavaScript` with typed args |
| Injecting 3 MB Mermaid via JS bridge on every diagram window | 3 MB IPC round-trip per window; no bytecode caching | `<script src>` in template HTML |
| Synchronous disk read on first Mermaid use (main thread) | Blocks main thread for ~5-20 ms; jank on first diagram | Pre-load on background thread at app start, or eliminate with `<script src>` approach |
| Static `mermaidJSLoaded` and `mermaidJS` without `@MainActor` annotation | Latent data race if any future refactor moves the call off main thread | Annotate `WebContentView` with `@MainActor` or extract to thread-safe type |
| `fatalError` on missing bundle resource | Crashes production with no user-visible error | Graceful error dialog with fallback inline template |
| `developerExtrasEnabled` in production builds | Exposes full DOM and JS execution to end users | Gate with `#if DEBUG` |
| Dark mode suppression via hardcoded CSS colors | White page in dark chrome window; visually broken | Not in scope per PROJECT.md, but a CSS `@media` block costs nothing |
| Polling or timers for chunk injection timing | Adds unnecessary overhead; couples timing to wall clock | `requestAnimationFrame` in JS or the existing `setTimeout(fn, i * 16)` stagger |
| Re-creating `WKWebView` instances instead of reusing | Each new instance may trigger WebKit process re-init | Warm-up pattern at launch; reuse where possible |
| File watching / live reload | Out of scope per PROJECT.md; adds complexity and state | Documented exclusion — revisit only if core value changes |

---

## Feature Dependencies

```
Memory-mapped file read (Feature 2)
  → prerequisite for: streaming parse (Feature 8)
  → prerequisite for: large file correctness (table stakes)

WKWebView warm-up (Feature 5)
  → makes sub-100ms first paint achievable (table stakes)
  → independent of all other features

Fix retain cycle (Feature 6)
  → prerequisite for: correct memory behavior (table stakes)
  → independent of rendering pipeline changes

N-chunk rendering (Feature 1)
  → prerequisite for: smooth load of large files
  → depends on: file being read (Feature 2 helps, not required)

Mermaid via <script src> (Feature 3)
  → independent — can ship without any other change
  → subsumes: mermaid synchronous disk read fix (CONCERNS.md)

callAsyncJavaScript (Feature 4)
  → enhances: N-chunk rendering (Feature 1)
  → independent of other features
```

---

## MVP for This Milestone

The milestone goal is sub-100ms launch, 10 MB+ file support, reduced memory.

**Priority 1 — Must have (blocks goals):**
1. Fix retain cycle (Feature 6) — memory cannot be "reduced" while windows leak
2. Mermaid via `<script src>` (Feature 3) — eliminates 3 MB bridge call, fixes main-thread disk read
3. Memory-mapped file read (Feature 2) — enables 10 MB+ without OOM
4. WKWebView warm-up (Feature 5) — the primary lever for sub-100ms first paint

**Priority 2 — High value, lower risk:**
5. N-chunk rendering (Feature 1) — needed for large files to load without jank
6. `callAsyncJavaScript` with typed args (Feature 4) — correctness fix, minor performance gain
7. Explicit `suppressesIncrementalRendering = false` (Feature 9) — one-line, zero risk

**Priority 3 — Polish:**
8. Window frame persistence (Feature 7) — correctness fix, improves UX
9. Streaming file read (Feature 8) — only matters for 50 MB+ files; memory mapping handles most cases

**Defer:**
- Dark mode — explicitly out of scope (PROJECT.md)
- File watching — explicitly out of scope (PROJECT.md)
- Sandbox entitlements — separate infrastructure concern, not a performance feature

---

## Observations from Competitive Landscape

**MacDown:** Uses a separate WebKit process for preview, decoupled from editor. Preview refreshes asynchronously. Native AppKit text views for editing keep keystroke response under 10 ms. Architecture insight: decoupling parse/render from the UI thread (already done in MDViewer) is the correct pattern.

**Typora:** Electron-based; 300+ MB RAM at idle, seconds to launch. MDViewer's native approach already beats this category structurally.

**QuickMD / ShowMeMyMD / OpenMark:** SwiftUI-based native apps. Launch fast because they compile to native Metal rendering paths. MDViewer's AppKit + WKWebView approach is heavier than pure SwiftUI + `Text`, but supports the HTML/CSS/JS rendering pipeline needed for Mermaid and LaTeX typography.

**Apple Preview (PDF):** Uses on-demand page rendering — only renders pages visible in the viewport. Keeps decoded bitmaps in RAM for instant scroll. For MDViewer, the analogous technique is N-chunk injection: render only what fits on screen, inject remaining content as the user scrolls.

**TextKit 2 (code editors on macOS 13+):** `NSTextViewportLayoutController` only lays out text fragments visible in the viewport. For a markdown viewer using WKWebView, the equivalent is browser-side virtual DOM — not directly applicable, but the principle (only render what is visible) should inform how chunks are sized relative to screen height.

---

## Sources

- Apple Developer Documentation: WKWebViewConfiguration, WKWebView.callAsyncJavaScript, Data(contentsOf:options:), NSTextViewportLayoutController — [developer.apple.com](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration)
- Apple File Management Guide: Mapping Files Into Memory — [developer.apple.com/library/archive](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html)
- WKWebView WarmUper pattern — [github.com/bernikovich/WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper)
- WKWebView memory leaks analysis — [embrace.io/blog/wkwebview-memory-leaks](https://embrace.io/blog/wkwebview-memory-leaks/)
- ChimeHQ TextViewBenchmark (TextKit 2 viewport layout) — [github.com/ChimeHQ/TextViewBenchmark](https://github.com/ChimeHQ/TextViewBenchmark)
- Swift Forums: Memory-mapped file discussion — [forums.swift.org](https://forums.swift.org/t/what-s-the-recommended-way-to-memory-map-a-file/19113)
- WKWebView callAsyncJavaScript: iOS 14 new features — [nemecek.be/blog/32](https://nemecek.be/blog/32/ios-14-what-is-new-for-wkwebview)
- QLMarkdown (cmark-gfm Quick Look reference) — [github.com/sbarex/QLMarkdown](https://github.com/sbarex/QLMarkdown)
- Apple WWDC 2019: Optimizing App Launch — [developer.apple.com/videos/play/wwdc2019/423](https://developer.apple.com/videos/play/wwdc2019/423/)
- Apple WWDC 2021: Meet TextKit 2 — [developer.apple.com/videos/play/wwdc2021/10061](https://developer.apple.com/videos/play/wwdc2021/10061/)
- cmark-gfm repository — [github.com/github/cmark-gfm](https://github.com/github/cmark-gfm)
