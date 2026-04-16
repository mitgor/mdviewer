# Feature Landscape: v2.1 Deep Rendering Optimization

**Domain:** Deep rendering optimization for native macOS markdown viewer
**Researched:** 2026-04-16
**Focus:** Five proposed optimizations to achieve sub-100ms launch-to-paint

---

## Current Baseline

- **Warm launch time:** 184.50ms on M4 Max (measured with OSSignposter)
- **Target:** Sub-100ms launch-to-first-paint
- **Budget to cut:** ~85ms minimum
- **Existing optimizations already shipped (v1 + v2.0):**
  - Memory-mapped file read (`mappedIfSafe`)
  - Progressive chunking (<=64KB block boundaries, N-chunk)
  - Single WKWebView pre-warm (saves ~40ms on first file)
  - Background-thread parsing
  - Cached regex, single-pass entity encoding
  - Batched JS chunk injection via `callAsyncJavaScript`
  - Mermaid script-src injection (no evaluateJavaScript for 3MB payload)
  - WeakScriptMessageProxy (retain cycle fixed)

### Where Time Is Spent (estimated breakdown of 184.50ms)

| Phase | Est. Time | Notes |
|-------|-----------|-------|
| File read (mappedIfSafe) | ~1-2ms | Already optimized |
| cmark parse | ~3-5ms | Already fast; C library |
| Mermaid regex scan | ~1-2ms | Two regex passes over HTML |
| Block-tag regex chunking | ~1-2ms | Regex scan for split points |
| String(cString:) copy | <1ms | C string -> Swift String |
| Template concatenation | <1ms | Already optimized with SplitTemplate |
| **loadHTMLString + WebKit pipeline** | **~80-120ms** | IPC transfer, HTML parse, CSS layout, paint, firstPaint callback |
| WKWebView init (pre-warmed) | ~0ms | Already pre-warmed for first file |
| WKWebView init (2nd+ file) | ~30-40ms | No pre-warm available |

**Key insight:** The Swift-side pipeline (file read through template assembly) takes ~10-15ms total. The WKWebView pipeline (loadHTMLString through firstPaint callback) takes ~80-120ms. The optimization budget is dominated by WebKit, not by the Swift code.

---

## Table Stakes

Optimizations that directly address measured bottlenecks with proven patterns.

### 1. WKWebView Warm Pool (2-3 Pre-warmed Views)

| Attribute | Value |
|-----------|-------|
| **Complexity** | Low |
| **Est. savings** | 30-40ms on 2nd+ file; 0ms on first file |
| **Confidence** | HIGH |
| **Risk** | LOW |

**What it does:** Extends the existing single-`preWarmedContentView` pattern to a pool of 2-3 pre-created WKWebView instances. When a file opens, a view is dequeued from the pool. Optionally, closed views are recycled (load `about:blank`, re-pool).

**Why it's table stakes:** The app already proves this pattern works -- the single pre-warm in `AppDelegate` saves ~40ms on the first file. But opening a second file while the first is displayed pays the full WKWebView init cost (~30-40ms) because the pre-warmed view was consumed. Multi-file workflows are the primary use case (drag multiple .md files onto the Dock icon).

**Architecture impact:** Minimal. Replace `preWarmedContentView: WebContentView?` with a `WebViewPool` class that manages a FIFO queue of pre-created views. Pool creates replacement views lazily after dequeue.

**Dependencies:** None. Fully independent of all other features.

**Implementation notes:**
- Memory cost: ~15-30MB per idle WKWebView. Pool of 3 = ~45-90MB. Acceptable for desktop app.
- WKProcessPool is auto-shared on macOS 12+ (noted in PROJECT.md Context section), so no manual pool management needed.
- Create pool views in `applicationDidFinishLaunching` after first-paint completes (don't compete with initial file render).
- Recycling on window close is optional but reduces steady-state memory.

**Evidence:** [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper) validates the pool pattern. MDViewer's own pre-warm code proves it works.

---

### 2. Vendored swift-cmark with Direct-to-Chunk AST Walking

| Attribute | Value |
|-----------|-------|
| **Complexity** | High |
| **Est. savings** | 5-15ms (eliminates regex passes + intermediate HTML allocation) |
| **Confidence** | MEDIUM |
| **Risk** | MEDIUM-HIGH |

**What it does:** Instead of:
1. `cmark_render_html_with_mem()` -> monolithic HTML string (~150KB for 100KB markdown)
2. `processMermaidBlocks()` -> regex scan entire HTML for mermaid code blocks
3. `chunkHTML()` -> regex scan entire HTML for block tag boundaries

Walk the AST once using `cmark_iter_new`/`cmark_iter_next`, emitting HTML directly into chunk buffers. Mermaid detection happens inline (check `CMARK_NODE_CODE_BLOCK` + `cmark_node_get_fence_info` for "mermaid"). Chunk boundaries happen at top-level block EXIT events when byte budget is exceeded.

**Why it's table stakes:** This collapses three serial passes into one. For a 100KB markdown file producing ~150KB HTML, it eliminates ~300KB of redundant regex scanning and one large intermediate allocation. More importantly, it's the architectural foundation for streaming and NSTextView rendering.

**Architecture impact:** HIGH. Requires:
- Vendoring swift-cmark as a local SPM package (currently remote `gfm` branch, revision `924936d`)
- Writing a `ChunkedHTMLRenderer` that mirrors `S_render_node` in `html.c` (~380 lines covering all node types) but emits into chunked buffers
- Supporting GFM extension render callbacks (`node->extension->html_render_func`) for table, strikethrough, autolink, tasklist

**Key findings from cmark source analysis:**

The existing `cmark_render_html_with_mem` (html.c:487-517) is just an iterator loop:
```c
cmark_iter *iter = cmark_iter_new(root);
while ((ev_type = cmark_iter_next(iter)) != CMARK_EVENT_DONE) {
    cur = cmark_iter_get_node(iter);
    S_render_node(&renderer, cur, ev_type, options);
}
```

The `cmark_html_renderer` struct (render.h:37-46) carries state:
```c
struct cmark_html_renderer {
    cmark_strbuf *html;      // output buffer -- this is what we'd split into chunks
    cmark_node *plain;       // NULL except inside image alt text
    cmark_llist *filter_extensions;
    unsigned int footnote_ix;
    unsigned int written_footnote_ix;
    void *opaque;
};
```

**Approach options:**
1. **Fork html.c directly** -- copy `S_render_node` and modify to emit chunks. Pros: exact output parity guaranteed. Cons: must maintain fork when cmark updates.
2. **Use public API only** -- render each top-level child node separately via `cmark_render_html_with_mem(child, ...)`. Pros: no internal API dependency. Cons: footnotes break (they reference across nodes), extension state may not carry across calls.
3. **Hybrid** -- use iterator with public accessors, but write the HTML emission in Swift calling `cmark_node_get_literal`, `cmark_node_get_fence_info`, etc. Pros: no C fork. Cons: must reimplement all HTML escaping, entity encoding, and extension-specific rendering in Swift.

**Recommendation:** Option 1 (fork html.c). The function is self-contained (~380 lines), well-structured, and the output format must match exactly. A fork with chunk-splitting added is safer than reimplementing.

**Dependencies:** None, but enables Features 3, 4, and 5.

**Evidence:** cmark-gfm.h line 259: "One natural application is an HTML renderer, where an ENTER event outputs an open tag and an EXIT event outputs a close tag." The API is explicitly designed for this.

---

## Differentiators

Optimizations that go beyond standard patterns. High potential but higher risk/complexity.

### 3. Streaming Parse Pipeline (Incremental Feed, Early First-Screen Emit)

| Attribute | Value |
|-----------|-------|
| **Complexity** | High |
| **Est. savings** | 2-8ms (first-paint latency only; total time unchanged) |
| **Confidence** | LOW |
| **Risk** | MEDIUM |

**What it does:** Instead of reading the complete file, then parsing the complete file, then walking the AST: read and feed bytes to `cmark_parser_feed` incrementally, then call `cmark_parser_finish`, then walk. The parse overlaps with file read.

**Reality check -- critical limitation:** `cmark_parser_feed` accepts incremental input, but `cmark_parser_finish` must be called before the AST is available. There is **no partial AST emission**. You cannot walk the AST until the entire file has been fed and finished. This means:
- File read and parse can overlap (save ~1-2ms)
- But first-chunk emission cannot happen until the full file is parsed
- The savings are real but marginal for typical markdown files (<1MB) on NVMe SSDs

**Where this would actually matter:** Files >10MB where read time becomes significant. But `mappedIfSafe` already makes reads nearly free (memory-mapped, no copy). The parse itself for a typical file is 3-5ms.

**Honest savings estimate:** On M4 Max with NVMe, overlapping a ~1ms read with a ~4ms parse saves at most ~1ms. For larger files (10MB), read might take ~3ms, parse ~15ms, overlap saves ~3ms. Real-world savings: 1-3ms for typical files, 3-8ms for very large files.

**Architecture impact:** Moderate. Requires changing `renderFullPage(fileURL:template:)` to use `DispatchIO` or `FileHandle` for chunked reads feeding into `cmark_parser_feed`. The parse and read run on the same background thread (cmark is not thread-safe).

**Dependencies:** Vendored swift-cmark (Feature 2). Streaming feed already uses the public `cmark_parser_feed` API, but AST walking for chunked output requires vendored access.

**Evidence:** cmark-gfm.h lines 597-608 document the streaming interface explicitly. But the limitation (no partial AST) means the savings are constrained.

---

### 4. Zero-Copy C String to JS Bridge

| Attribute | Value |
|-----------|-------|
| **Complexity** | Very High |
| **Est. savings** | 1-3ms (speculative) |
| **Confidence** | LOW |
| **Risk** | HIGH |

**What it does:** Eliminate the `String(cString: htmlCStr)` allocation in `parseMarkdownToHTML` (line 127 of MarkdownRenderer.swift) and the subsequent Swift String manipulations. Pass C buffer bytes more directly to WKWebView.

**Reality check -- the IPC boundary dominates:**
1. `String(cString: htmlCStr)` for 150KB HTML takes <0.1ms on M4 Max. This is not a bottleneck.
2. Template concatenation (`prefix + firstChunk + suffix`) is another ~0.1ms. Also not a bottleneck.
3. `loadHTMLString` serializes the string across IPC to the WebKit process regardless of how it was constructed in Swift. This IPC transfer takes 2-5ms for 150KB and is unavoidable.

**Possible approaches:**
- `String(bytesNoCopy:length:encoding:freeWhenDone:)` -- avoids one copy but still serializes across IPC
- Write HTML to temp file, use `loadFileURL` -- trades string copy for file IO; may actually be slower for small content
- `WKURLSchemeHandler` serving content from memory -- most promising but adds significant complexity (custom URL scheme, async handler, navigation delegate changes)

**Why the savings are speculative:** The total cost of Swift String operations on the content is <0.5ms. The IPC boundary (loadHTMLString -> WebKit process) costs 2-5ms and is unavoidable with any approach. Zero-copy within Swift saves <0.5ms. Zero-copy across IPC is not possible with public WebKit APIs.

**Architecture impact:** Very high for `WKURLSchemeHandler` approach. Moderate for `bytesNoCopy`. Either way, the savings don't justify the complexity.

**Dependencies:** Vendored swift-cmark (Feature 2) if the AST walker writes directly to a C buffer (avoiding Swift String entirely until the last moment).

**Recommendation:** Do not pursue. The <0.5ms savings in Swift String operations are not worth the complexity. Focus optimization effort on reducing the WebKit pipeline time instead.

---

### 5. Native NSTextView Rendering for Mermaid-Free Files

| Attribute | Value |
|-----------|-------|
| **Complexity** | Very High |
| **Est. savings** | 60-100ms (bypasses WKWebView entirely) |
| **Confidence** | LOW |
| **Risk** | VERY HIGH |

**What it does:** For markdown files without mermaid diagrams, bypass WKWebView and render using NSTextView with NSAttributedString built from the cmark AST. NSTextView renders directly in the app process with zero IPC overhead.

**Why the savings are real:** The ~80-120ms WKWebView pipeline (IPC + HTML parse + CSS layout + paint + firstPaint callback) is eliminated entirely. NSTextView + NSAttributedString layout for equivalent content takes ~5-15ms.

**Critical problems that make this very high risk:**

1. **Feature parity requires reimplementing template.html styling.** The current template has sophisticated CSS: Latin Modern Roman fonts at specific sizes, code block backgrounds with border-radius, GFM table styling with alternating row colors, task list checkboxes, blockquote left borders, horizontal rules, link styling. Every CSS rule must become NSAttributedString paragraph/character style attributes.

2. **GFM tables in NSTextView are extremely painful.** NSTextView has no native table support. You need NSTextTable + NSTextTableBlock, which are poorly documented, don't support horizontal scrolling, and have rendering quirks. Tables are a GFM table-stakes feature.

3. **Code blocks need NSTextTab + custom background drawing.** NSTextView doesn't natively support background colors on paragraph ranges. You'd need custom drawing via `NSLayoutManager` (TextKit 1) or `NSTextLayoutFragment` (TextKit 2).

4. **Two rendering paths = permanent maintenance tax.** Every visual fix, every font change, every spacing adjustment must be applied in both template.html and the attributed string builder. Visual parity testing becomes a permanent requirement.

5. **NSAttributedString's HTML import uses WebKit internally.** `NSAttributedString(html:)` calls into WebKit, so you cannot use it as a shortcut -- you must build the attributed string from the cmark AST manually.

6. **PDF export and print would need a separate path.** Current PDF export uses `WKWebView.createPDF()`. NSTextView has its own printing infrastructure but produces different output. Two print paths.

7. **Monospace toggle (Cmd+M) needs reimplementation.** Currently handled by a JS function in template.html. Would need attributed string font swapping.

**Architecture impact:** This is building a second rendering engine. New classes needed:
- `ASTToAttributedStringRenderer` -- walks cmark AST, builds NSAttributedString
- `NativeContentView` (NSTextView wrapper) -- parallel to WebContentView
- Routing logic in AppDelegate to pick renderer based on mermaid presence
- Shared protocol or abstraction for ContentView (both native and web variants)

**Dependencies:** Vendored swift-cmark with AST walking (Feature 2) is mandatory. You need direct AST access to build attributed strings.

**The honest question:** Is 40-70ms of savings worth building and maintaining a second rendering engine permanently? The answer depends on whether sub-100ms is achievable any other way.

---

## Anti-Features

Features to explicitly NOT build for this optimization milestone.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| JavaScript-side chunking | HTML must still fully transfer across IPC; moving chunk logic to JS doesn't reduce IPC cost | Keep chunking in Swift/C before WKWebView handoff |
| Precompiled HTML caching | Adds disk IO, staleness checks; viewer should always show current file content | Always render fresh from source |
| Multi-threaded cmark parsing | cmark uses internal state machines; not thread-safe. Would corrupt AST | Single-threaded parse; optimize the single pass |
| SwiftUI migration | Adds launch overhead; provides no rendering speed benefit for this use case | Stay on AppKit + WKWebView |
| Custom WKURLSchemeHandler for content serving | Adds async handler complexity, custom URL scheme; saves <2ms vs loadHTMLString | Stick with loadHTMLString |
| Partial AST rendering (render before parse completes) | cmark has no partial AST API; cmark_parser_finish required before any traversal | Accept parse-then-render serial dependency |
| WebAssembly markdown renderer in WKWebView | Slower than native C cmark; adds WASM compilation overhead | Use cmark C API directly from Swift |

---

## Feature Dependencies

```
WKWebView Warm Pool (1) -----> independent, no dependencies

Vendored swift-cmark (2) ----> Streaming Parse Pipeline (3)
                          \--> Zero-Copy Bridge (4) -- RECOMMENDED: do not pursue
                           \-> Native NSTextView Rendering (5)
```

**Critical path:** Vendored swift-cmark (Feature 2) is the foundation for 3 of the 4 remaining features. It must come first.

---

## MVP Recommendation

### Phase 1: Foundation + Quick Win
1. **WKWebView warm pool** -- Low complexity, proven pattern, immediate savings for multi-file
2. **Vendor swift-cmark as local SPM** -- No behavior change, just dependency management

### Phase 2: Core Optimization
3. **Direct-to-chunk AST walking** -- The main architectural win. Eliminates regex passes, reduces allocations, produces chunks directly from the AST.

### Phase 3: Evaluate and Decide
4. **Measure results.** If under 150ms, streaming pipeline (Feature 3) adds marginal value. If still over 150ms, investigate where time is spent in WebKit pipeline.

### Defer
- **Zero-copy C string to JS bridge** (Feature 4) -- <0.5ms savings for very high complexity. Do not build.
- **Native NSTextView rendering** (Feature 5) -- Only pursue if sub-100ms is confirmed impossible with WKWebView and the project decides the maintenance cost is acceptable.

---

## Realistic Performance Budget

| Scenario | First File | 2nd+ File | Notes |
|----------|-----------|-----------|-------|
| **Current baseline** | 184.50ms | ~220ms | Measured; 2nd file has no pre-warm |
| + Warm pool | 184.50ms | ~184ms | Pool covers 2nd+ files |
| + AST walking (no regex) | ~170-175ms | ~170-175ms | Saves ~10-15ms from eliminating regex passes and intermediate string |
| + Streaming pipeline | ~168-173ms | ~168-173ms | Marginal; 2-5ms overlap savings |
| **Realistic achievable (WKWebView path)** | **~165-175ms** | **~165-175ms** | |
| + NSTextView path (mermaid-free) | **~70-100ms** | **~70-100ms** | Bypasses WebKit entirely |

### Honest Assessment

**Sub-100ms is likely not achievable while using WKWebView for rendering.** The WebKit pipeline (loadHTMLString -> HTML parse -> CSS layout -> paint -> IPC callback) takes ~80-120ms on its own, regardless of how fast the content is generated. The Swift-side pipeline is already fast (~10-15ms). Optimizing it further yields diminishing returns.

**To reach sub-100ms, one of these must happen:**
1. **NSTextView for mermaid-free files** -- proven feasible but very high maintenance cost
2. **Apple improves WKWebView first-load performance** -- not in our control
3. **Revise the target** -- sub-150ms is realistic and still "instant" to human perception

**Recommended target revision:** Sub-150ms all files with WKWebView (achievable with Features 1-3). Sub-100ms deferred to future milestone if NSTextView path is approved.

---

## Sources

- cmark-gfm.h iterator API documentation -- read directly from `/Users/mit/Library/Developer/Xcode/DerivedData/MDViewer-*/SourcePackages/checkouts/swift-cmark/src/include/cmark-gfm.h` (HIGH confidence)
- cmark html.c `S_render_node` and `cmark_render_html_with_mem` -- read directly from source (HIGH confidence)
- cmark render.h `cmark_html_renderer` struct -- read directly from source (HIGH confidence)
- MDViewer source: `MarkdownRenderer.swift`, `WebContentView.swift`, `AppDelegate.swift`, `MarkdownWindow.swift` -- read directly (HIGH confidence)
- [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper) -- WKWebView warm pool pattern
- [Embrace: WKWebView Memory](https://embrace.io/blog/wkwebview-memory-leaks/) -- memory cost per instance
- [Apple Developer Forums: WKWebView Loading](https://developer.apple.com/forums/thread/725330) -- loadHTMLString performance
- [Eclectic Light: SwiftUI text views](https://eclecticlight.co/2024/05/07/swiftui-on-macos-text-rich-text-markdown-html-and-pdf-views/) -- NSTextView vs WKWebView
- [Benchmarking Markdown Parsers](https://blog.services.aero2x.eu/benchmarking-popular-markdown-parsers-on-ios.html) -- NSAttributedString performance
- [Incremental Markdown Parsing](https://dev.to/kingshuaishuai/eliminate-redundant-markdown-parsing-typically-2-10x-faster-ai-streaming-4k94) -- streaming parse analysis
- [commonmark/cmark](https://github.com/commonmark/cmark) -- cmark architecture reference
- [swiftlang/swift-cmark](https://github.com/swiftlang/swift-cmark) -- Apple's fork (used by MDViewer)
