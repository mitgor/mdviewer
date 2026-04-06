# Architecture Patterns: Rendering Pipeline Optimization

**Domain:** macOS markdown viewer — speed and memory optimization
**Researched:** 2026-04-03
**Overall confidence:** HIGH (grounded in actual codebase, verified APIs, official docs)

---

## Current State Summary

The existing pipeline has these measurable bottlenecks (derived from CONCERNS.md and code reading):

| Bottleneck | Location | Impact |
|-----------|----------|--------|
| `String(contentsOf:)` loads entire file | `MarkdownRenderer.renderFullPage(fileURL:)` line 58 | Entire file in memory; blocks background thread for large files |
| `chunkHTML` produces at most 2 chunks | `MarkdownRenderer.chunkHTML` lines 153–165 | Single `evaluateJavaScript` call passes multi-MB HTML string |
| Manual JS string construction in `injectRemainingChunks` | `WebContentView` lines 74–103 | Character-by-character escaping loop; incorrect escaping of null bytes / surrogates |
| Mermaid JS read from disk on main thread on first use | `WebContentView.loadAndInitMermaid()` lines 177–191 | Synchronous 3 MB read blocks main thread |
| Mermaid JS injected via 3 MB `evaluateJavaScript` bridge call | `WebContentView.loadAndInitMermaid()` line 188 | Bridge serialization cost per window |
| WKWebView process initialization on first window | `WebContentView.init` | 80–200ms cold start; WKWebView spawns a new web content process on first use |
| `encodeHTMLEntities` uses character-by-character loop | `MarkdownRenderer` lines 138–150 | O(n) per character for Mermaid source; Unicode grapheme cluster iteration is slow |

---

## Recommended Architecture

The optimized pipeline is a producer–consumer design where file I/O, parsing, HTML generation, and injection are all separately pipelined, with WKWebView pre-warmed before any file is opened.

### System Diagram

```
App Launch
  │
  ├── [main thread] load SplitTemplate from bundle (already done)
  ├── [main thread] pre-warm WKWebView (new: allocate one WKWebView off-screen)
  └── [global queue] pre-load Mermaid JS into memory (new: move out of first-use path)

File Open Request
  │
  ├── [global queue, .userInitiated]
  │     ├── Data(contentsOf:options:.mappedIfSafe)   ← memory-mapped read (new)
  │     ├── cmark_parser_feed (unchanged C call)
  │     ├── cmark_parser_finish → AST
  │     ├── cmark_render_html → full HTML string
  │     ├── processMermaidBlocks (unchanged logic)
  │     └── chunkHTMLIntoN(targetBytes:) → [Chunk]  ← true N-chunk split (new)
  │
  └── [main thread]
        ├── dequeue pre-warmed WKWebView (or create new if pool exhausted)
        ├── loadHTMLString(template.prefix + chunks[0] + template.suffix)
        │     (unchanged: baseURL = Bundle.main.resourceURL for font resolution)
        └── on firstPaint signal:
              ├── show window (unchanged)
              ├── injectChunks(chunks[1...]) via callAsyncJavaScript (new: typed args)
              └── if hasMermaid: initMermaid via <script src> (new: no bridge call)
```

---

## Component Changes

### 1. MarkdownRenderer — File Reading

**Change:** Replace `String(contentsOf:)` with `Data(contentsOf:options:.mappedIfSafe)` followed by `String(data:encoding:)`.

**Why:** `Data(contentsOf:options:.mappedIfSafe)` asks the OS to memory-map the file when it is on a local volume. For files 1 MB+ this means only the pages actually accessed are loaded into RAM; the remainder stays on disk until needed. This is the standard Swift idiom for large-file reading. (HIGH confidence — documented in Swift Forums and Apple sample code.)

**Caveats:** `.mappedIfSafe` silently falls back to a normal read for remote volumes (SMB, network shares), so no crash risk. Do not use `.alwaysMapped` — it crashes if the file disappears mid-read.

**New signature:**
```swift
func renderFullPage(fileURL: URL, template: SplitTemplate) -> RenderResult? {
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
          let markdown = String(data: data, encoding: .utf8) else {
        return nil
    }
    return renderFullPage(markdown: markdown, template: template)
}
```

This keeps the rest of the pipeline unchanged. For streaming support on truly giant files (50 MB+), DispatchIO can feed the cmark parser in blocks using `cmark_parser_feed` repeatedly before calling `cmark_parser_finish` — but this is only worth pursuing after the `.mappedIfSafe` change shows insufficient gain under profiling.

---

### 2. MarkdownRenderer — True N-Chunk Splitting

**Change:** Replace the 2-chunk fixed split in `chunkHTML` with byte-budget-based N-chunk splitting.

**Why:** The current code always produces at most 2 chunks. For a 10 MB markdown file the "remaining" chunk is still a single enormous HTML blob passed to `evaluateJavaScript`. The JS engine must parse and eval that string before rendering can proceed, which stalls the web content process render thread.

**Target:** Split into chunks of approximately 64 KB of HTML each (configurable). The JS side already supports arrays of chunks with 16ms staggering, so no JS changes are needed.

**New algorithm:**
```swift
private func chunkHTML(_ html: String, targetBytes: Int = 65_536) -> [String] {
    let nsString = html as NSString
    let matches = Self.blockTagRegex.matches(
        in: html, range: NSRange(location: 0, length: nsString.length)
    )

    // No chunking needed for small documents
    guard matches.count > chunkThreshold else { return [html] }

    var chunks: [String] = []
    var lastSplitLocation = 0
    var bytesInCurrentChunk = 0

    for match in matches {
        let loc = match.range.location
        let bytesSinceLastSplit = (loc - lastSplitLocation)

        if bytesInCurrentChunk + bytesSinceLastSplit >= targetBytes && lastSplitLocation > 0 {
            let range = NSRange(location: lastSplitLocation, length: loc - lastSplitLocation)
            chunks.append(nsString.substring(with: range))
            lastSplitLocation = loc
            bytesInCurrentChunk = 0
        } else {
            bytesInCurrentChunk += bytesSinceLastSplit
        }
    }

    // Append remainder
    if lastSplitLocation < nsString.length {
        chunks.append(nsString.substring(from: lastSplitLocation))
    }

    return chunks.isEmpty ? [html] : chunks
}
```

The first chunk stays inlined into the template (unchanged). All subsequent chunks inject via the JS bridge with 16ms spacing, keeping the render thread free between each paint.

---

### 3. MarkdownRenderer — encodeHTMLEntities

**Change:** Replace character-by-character loop with chained `replacingOccurrences` calls.

**Why:** Swift's `String` character iteration walks Unicode grapheme clusters — slow for ASCII-heavy Mermaid source. `replacingOccurrences(of:with:)` is implemented in Foundation with optimized byte-level scanning and is faster for the typical Mermaid input (mostly ASCII with occasional `<`, `>`, `"`, `&`). (MEDIUM confidence — common advice in Swift Forums; exact speedup depends on input shape.)

```swift
private func encodeHTMLEntities(_ input: String) -> String {
    input
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
```

Order matters: `&` must be replaced first to avoid double-encoding.

---

### 4. WebContentView — Safe Chunk Injection

**Change:** Replace the manual JS template-literal construction in `injectRemainingChunks` with `callAsyncJavaScript(_:arguments:in:in:completionHandler:)`.

**Why:** `callAsyncJavaScript` accepts a Swift dictionary as `arguments` and handles all JSON serialization and JS escaping automatically. This eliminates the manual `\`, `` ` ``, `$` escape loop and the silent correctness bug with null bytes and Unicode surrogates. Available macOS 11+; the project targets macOS 13+, so no availability guard needed. (HIGH confidence — documented API, macOS 11+ availability well-established.)

**New injection:**
```swift
private func injectRemainingChunks() {
    guard !remainingChunks.isEmpty else { return }
    let chunks = remainingChunks
    remainingChunks = []

    let js = """
    (function(chunks) {
        chunks.forEach(function(chunk, i) {
            setTimeout(function() { window.appendChunk(chunk); }, i * 16);
        });
    })(chunks)
    """

    webView.callAsyncJavaScript(
        js,
        arguments: ["chunks": chunks],
        in: nil,
        in: .page,
        completionHandler: nil
    )
}
```

The `chunks` array is serialized as a JSON array by WebKit before the JS executes — no manual escaping required, no injection vulnerability.

---

### 5. WebContentView — Mermaid via `<script src>` Tag

**Change:** Remove the `evaluateJavaScript(js)` bridge call for 3 MB mermaid.min.js. Instead, include a conditional `<script src="mermaid.min.js">` tag in `template.html` and control it via a CSS class or a data attribute on `<body>`.

**Why:** The current approach serializes 3 MB through the Swift/JS bridge for every window that has Mermaid. `loadHTMLString` already sets `baseURL = Bundle.main.resourceURL`, so `src="mermaid.min.js"` resolves correctly from the bundle. WebKit loads script resources in the web content process directly from disk — no bridge overhead. (HIGH confidence — the project already uses this baseURL pattern for fonts; the same mechanism applies to JS.)

**Implementation approach:**

Option A (simplest): Always include `<script src="mermaid.min.js" defer></script>` in `template.html`. The `defer` attribute means it downloads after HTML parsing and executes after DOMContentLoaded. On documents without Mermaid, `initMermaid()` simply finds no `.mermaid-placeholder` elements and returns immediately. Cost: ~3 MB loaded from disk even for non-Mermaid documents (mitigated by OS file cache after first load).

Option B (no unnecessary load): Inject `<script src="mermaid.min.js">` via a `WKUserScript` with injection time `.atDocumentEnd`, but only when `hasMermaid == true`. This avoids the 3 MB load for plain documents. The `WKUserScript` is added to the `WKWebViewConfiguration` before `loadHTMLString` is called, so it fires before `firstPaint`.

Option B is recommended because it preserves the lazy-load behavior and avoids disk reads for the common case (most markdown files have no Mermaid blocks).

**Remove from WebContentView:** `loadAndInitMermaid()`, `mermaidJS` static, `mermaidJSLoaded` static.

---

### 6. AppDelegate — WKWebView Pre-Warm

**Change:** Allocate one `WebContentView` at app launch and hold it in a pool. Reuse it for the first file open; create fresh instances for subsequent windows.

**Why:** WKWebView spawns a `com.apple.WebKit.WebContent` process on first instantiation. This takes 80–200ms on a cold system (measured community reports; no Apple-published benchmark, so MEDIUM confidence). Pre-warming eliminates this from the critical path for the first open — the most common Finder double-click use case.

**Implementation:**
```swift
// AppDelegate.swift
private var warmWebView: WebContentView?

func applicationDidFinishLaunching(_ notification: Notification) {
    loadTemplate()
    setupMenu()
    preWarmWebView()        // new
    preLoadMermaidJS()      // new — if keeping bridge approach
    NSApp.activate(ignoringOtherApps: true)
    // ... existing CLI arg handling
}

private func preWarmWebView() {
    let view = WebContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    // Load a minimal HTML page to force web content process spawn
    view.loadBlankForWarmup()
    warmWebView = view
}
```

```swift
// WebContentView.swift
func loadBlankForWarmup() {
    webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
}
```

In `displayResult`, consume `warmWebView` if available:
```swift
private func displayResult(_ result: RenderResult, for url: URL) {
    let contentView: WebContentView
    if let warm = warmWebView {
        warmWebView = nil
        contentView = warm
    } else {
        contentView = WebContentView(frame: .zero)
    }
    // ... rest unchanged
}
```

The warm view is 1x1 px and never added to a visible window, so it has no visual effect.

---

### 7. WebContentView — Retain Cycle Fix (prerequisite)

**Change:** Add a `deinit` that removes the script message handler, or use a weak-proxy wrapper.

**Why:** This is documented in CONCERNS.md as a confirmed retain cycle. Without fixing it, each window's `WebContentView` is never deallocated, accumulating memory per window open. This must be fixed before memory reduction can be measured.

**Minimal fix:**
```swift
deinit {
    webView.configuration.userContentController
        .removeScriptMessageHandler(forName: "firstPaint")
}
```

Better fix: use a weak-proxy `WKScriptMessageHandler` conformer that holds `weak var target: WebContentView?`, so the handler can be removed without needing `deinit` coordination.

---

### 8. WebContentView — firstPaint Guard

**Change:** Add a `hasProcessedFirstPaint: Bool` flag to prevent double-injection on reload.

**Why:** CONCERNS.md identifies that `DOMContentLoaded` can fire more than once on `loadHTMLString` reload. The `remainingChunks` array is already cleared after first injection, so re-injection is safe for chunks — but Mermaid injection uses a static flag that would block re-initialization on second fire.

```swift
private var hasProcessedFirstPaint = false

func loadContent(page: String, remainingChunks: [String], hasMermaid: Bool) {
    hasProcessedFirstPaint = false   // reset on each load
    // ...
}

func userContentController(...) {
    if message.name == "firstPaint" && !hasProcessedFirstPaint {
        hasProcessedFirstPaint = true
        delegate?.webContentViewDidFinishFirstPaint(self)
        injectRemainingChunks()
    }
}
```

---

## Data Flow — Optimized

```
[Launch]
  main: loadTemplate()             → SplitTemplate (unchanged)
  main: preWarmWebView()           → WebContent process spawned, warm
  global: preLoadMermaidJS()       → optional: loads mermaid.js string off-main (if keeping bridge approach)

[File Open]
  global (.userInitiated):
    Data(contentsOf: url, .mappedIfSafe)  → Data (OS maps pages lazily)
    String(data: data, .utf8)            → markdown String
    cmark_parser_feed/finish             → cmark AST (unchanged C call)
    cmark_render_html                    → full HTML String (unchanged)
    processMermaidBlocks                 → HTML + hasMermaid (unchanged logic, faster encode)
    chunkHTMLIntoN(targetBytes: 65536)   → [String] with N chunks

  main:
    dequeue warm WebContentView (or create new)
    loadHTMLString(prefix + chunks[0] + suffix, baseURL: resourceURL)
    makeKeyAndOrderFront (window hidden, alphaValue = 0)

  [WKWebView DOMContentLoaded → firstPaint message]:
  main (WKScriptMessageHandler):
    guard !hasProcessedFirstPaint
    hasProcessedFirstPaint = true
    delegate.webContentViewDidFinishFirstPaint → window.showWithFadeIn()
    callAsyncJavaScript(js, arguments: ["chunks": chunks[1...]])
    (if hasMermaid: WKUserScript already injected mermaid.min.js via <script src>)
```

---

## What Does Not Change

- `cmark_parser_feed` / `cmark_parser_finish` / `cmark_render_html_with_mem` call sequence — the C API is fast (<10ms for large files) and does not need modification
- `SplitTemplate` pre-split at launch — O(1) concatenation is already optimal
- Background thread dispatch for parsing — already correct, keep `DispatchQueue.global(qos: .userInitiated)`
- `WKScriptMessageHandler` firstPaint signal — still the correct trigger for fade-in
- 16ms stagger between chunk injections in JS — keep as-is; matches one frame at 60Hz
- `loadHTMLString` with `baseURL: Bundle.main.resourceURL` — correct for font resolution, do not switch to `loadFileURL` (adds sandboxing complexity, no meaningful performance gain here)
- PDF export / print workaround — orthogonal to this optimization milestone

---

## Build Order (Suggested Phase Sequence)

Order by: correctness first, highest-impact before low-impact, dependencies resolved.

**Phase 1 — Fix correctness blockers (enables accurate measurement)**
1. Fix retain cycle in `WebContentView.deinit` — without this, memory measurements are meaningless; each window leaks
2. Add `hasProcessedFirstPaint` guard — prevents subtle double-init bug that would mask Mermaid regressions

**Phase 2 — Chunk injection safety (medium-risk refactor)**
3. Switch `injectRemainingChunks` to `callAsyncJavaScript` with typed arguments — eliminates escaping bug, drops character loop

**Phase 3 — Large file throughput (highest memory impact)**
4. Switch file reading to `Data(contentsOf:options:.mappedIfSafe)` — reduces peak memory for 10 MB+ files
5. Implement true N-chunk splitting (64 KB target) — removes the remaining single-large-string JS injection

**Phase 4 — Startup latency (highest perceived speed impact)**
6. Pre-warm WKWebView at launch — eliminates 80–200ms web content process spin-up from first-file critical path
7. Fix `encodeHTMLEntities` to use `replacingOccurrences` — minor but measurable for large Mermaid diagrams

**Phase 5 — Mermaid memory (removes 3 MB bridge serialization)**
8. Switch Mermaid loading to `<script src>` via `WKUserScript` injection — eliminates bridge cost, WKWebView loads from disk directly

**Phase 6 — Window management (user-visible bugs)**
9. Fix `loadSavedFrame()` stub — implement `NSUserDefaults`-backed frame persistence
10. Fix per-file `frameSaveKey` — use file path hash to avoid last-write-wins collision

---

## Scalability Boundaries

| File Size | Current Behavior | After Optimization |
|-----------|-----------------|-------------------|
| <1 MB, <50 blocks | Single chunk, no injection | Same; no change |
| 1–5 MB, 50–500 blocks | 2 chunks; ~2 MB string in one `evaluateJavaScript` call | ~30 chunks of 64 KB; smooth injection over ~480ms at 16ms/chunk |
| 5–10 MB, 500+ blocks | Second chunk is 4–8 MB; JS engine stalls render thread | N chunks; memory-mapped so peak RSS is sub-linear in file size |
| 10 MB+ | `String(contentsOf:)` loads entire file into RAM; UI freeze risk | Memory-mapped; only accessed pages loaded; streaming is viable via DispatchIO if needed |

For files above ~50 MB the cmark AST itself becomes the dominant memory consumer (AST nodes are heap-allocated per block element). At that scale, chunked DispatchIO feeding into `cmark_parser_feed` with partial AST rendering becomes relevant — but this is out of scope for this milestone and requires a custom HTML renderer. Flag for a future research phase.

---

## Anti-Patterns to Avoid

### Anti-Pattern: Switch to `loadFileURL`
**What:** Replace `loadHTMLString` with `loadFileURL(url, allowingReadAccessTo: resourceDir)`.
**Why bad:** Adds a required sandboxing entitlement, changes security scope behavior, breaks the `{{FIRST_CHUNK}}` inline injection pattern (you'd need to write a temp file), and provides no measurable launch benefit over `loadHTMLString` with a correct `baseURL`.
**Instead:** Keep `loadHTMLString` with `baseURL: Bundle.main.resourceURL`.

### Anti-Pattern: Pre-parse at launch
**What:** Parse the markdown file in the background before the user has selected it (speculative pre-warm).
**Why bad:** You don't know which file the user will open next. Even for Finder double-click (where the file path is known early), parsing on the `application(_:openFile:)` path is already happening on a background queue, so the window is not blocked.
**Instead:** The WKWebView pre-warm (process spawn) is the correct speculative optimization because it is file-agnostic.

### Anti-Pattern: Use `DispatchIO` for files under 10 MB
**What:** Stream every file through `DispatchIO` chunks and progressively feed `cmark_parser_feed`.
**Why bad:** `DispatchIO` introduces significant code complexity (continuation-based async, buffer management). For files under 10 MB the OS page cache makes `Data(contentsOf:options:.mappedIfSafe)` effectively instant after first open. The complexity cost outweighs the gain in the common case.
**Instead:** Use `.mappedIfSafe` for all files. Add `DispatchIO` only if profiling reveals it as a bottleneck for the specific 10 MB+ case.

### Anti-Pattern: Increase chunk count indefinitely
**What:** Reduce chunk size to <4 KB to maximize smoothness.
**Why bad:** Each `evaluateJavaScript` / `callAsyncJavaScript` call crosses the process boundary (Swift UI process → WebContent process). Very small chunks cause high IPC overhead. 64 KB is empirically a good balance: large enough to amortize IPC cost, small enough to not stall the JS engine.
**Instead:** Target 32–128 KB per chunk. Profile with Instruments → Time Profiler on a representative large file.

---

## Sources

- Swift Forums — memory mapping: https://forums.swift.org/t/what-s-the-recommended-way-to-memory-map-a-file/19113
- Apple Developer Docs — `Data(contentsOf:options:)`: https://developer.apple.com/documentation/foundation/data/1779617-init
- Apple Developer Docs — `callAsyncJavaScript`: https://developer.apple.com/documentation/webkit/wkwebview/3656441-callasyncjavascript
- WKWebView warm-up community research: https://github.com/bernikovich/WebViewWarmUper
- Apple Developer Forums — WKWebView cold start: https://developer.apple.com/forums/thread/733774
- MDN — requestAnimationFrame: https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame
- HTML Streaming concepts: https://calendar.perfplanet.com/2025/revisiting-html-streaming-for-modern-web-performance/
- cmark-gfm upstream: https://github.com/github/cmark-gfm
- Custom font loading in WKWebView: https://sarunw.com/posts/how-to-use-custom-fonts-in-wkwebview/
- DispatchIO async patterns: https://losingfight.com/blog/2024/04/22/reading-and-writing-files-in-swift-asyncawait/

---

*Architecture research: 2026-04-03*
