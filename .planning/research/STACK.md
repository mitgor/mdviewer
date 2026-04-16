# Technology Stack: v2.1 Deep Optimization

**Project:** MDViewer v2.1 -- Deep Rendering Optimization
**Researched:** 2026-04-16
**Scope:** Vendored cmark, WKWebView pooling, streaming pipeline, zero-copy bridging, native text rendering

## Executive Summary

The existing stack (AppKit + WKWebView + cmark-gfm, Swift 5.9, macOS 13+) remains correct. This milestone adds no new external dependencies. All optimizations are achieved through: (1) forking the already-cloned swift-cmark to add a chunked HTML renderer in C, (2) pooling WKWebView instances, (3) eliminating intermediate string copies, and (4) adding an optional native NSTextView rendering path for simple documents.

---

## Recommended Stack Changes

### 1. Vendored swift-cmark with Chunked HTML Renderer

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Local swift-cmark fork | 0.29.0.gfm.13 | Markdown parsing + direct chunked HTML output | Eliminates post-hoc regex-based chunking entirely; chunks emitted at render time from AST traversal |

**Confidence:** HIGH (source code verified at `/Users/mit/Documents/GitHub/swift-cmark`)

**How to vendor:** Change `Package.swift` and `project.yml` to reference a local path instead of the remote git URL. The local fork at `/Users/mit/Documents/GitHub/swift-cmark` is already cloned and has its own optimization work tracked in its CLAUDE.md.

```yaml
# project.yml change
packages:
  swift-cmark:
    path: ../swift-cmark   # local vendored fork
```

```swift
// Package.swift change
.package(path: "../swift-cmark"),
```

**Specific C API additions to `html.c`:** Add a new function `cmark_render_html_chunked` that uses a callback instead of accumulating into a single `cmark_strbuf`. The modification is straightforward because:

1. The existing `cmark_render_html_with_mem` (html.c lines 505-538) already uses an iterator pattern (`cmark_iter_next_inline`) walking the AST.
2. The `S_render_node` function writes to `renderer->html` (a `cmark_strbuf*`).
3. The chunk boundary is when a top-level block EXIT event fires (depth-1 children of DOCUMENT node) and accumulated bytes exceed a threshold.

**New C API (add to `cmark-gfm.h`):**

```c
/* Callback invoked for each HTML chunk. 'data' is NOT null-terminated.
 * 'data' is valid only for the duration of the callback.
 * Return 0 to continue, non-zero to abort rendering. */
typedef int (*cmark_html_chunk_callback)(
    const char *data, size_t len, int is_last, void *userdata);

/* Render HTML in chunks, calling 'callback' at block boundaries
 * when accumulated output exceeds 'chunk_byte_limit'. */
CMARK_GFM_EXPORT
int cmark_render_html_chunked(
    cmark_node *root,
    int options,
    cmark_llist *extensions,
    size_t chunk_byte_limit,
    cmark_html_chunk_callback callback,
    void *userdata);
```

**Implementation strategy in `html.c`:** Fork `cmark_render_html_with_mem` into `cmark_render_html_chunked`. The key insight from reading the source: the iterator visits every node in the tree. We detect chunk boundaries by checking if `ev_type == CMARK_EVENT_EXIT` and `node->parent->type == CMARK_NODE_DOCUMENT` (i.e., a direct child of root just finished rendering). When `html.size >= chunk_byte_limit`, call the callback with `cmark_strbuf_cstr(&html)` and `html.size`, then `cmark_strbuf_clear(&html)`. After the loop ends, call the callback with `is_last=1` for remaining content.

The `cmark_html_renderer` struct (render.h lines 38-47) has an `opaque` field -- use this to store callback context (threshold, callback pointer, userdata) so `S_render_node` doesn't need modification.

**Estimated diff:** ~70 lines added to `html.c`, ~15 lines to `cmark-gfm.h`. Zero changes to existing functions -- purely additive.

**Mermaid detection at the C level:** Modify `S_render_node`'s `CMARK_NODE_CODE_BLOCK` case. When `node->as.code.info` matches "mermaid" (7-byte comparison), emit a `<div class="mermaid-placeholder" data-mermaid-source="...">` instead of `<pre><code class="language-mermaid">`. Set a flag (`renderer->opaque` or a new field) to track mermaid presence. This eliminates the Swift-side `processMermaidBlocks()` regex post-pass entirely.

The fence_info comparison in C:
```c
// In S_render_node, CMARK_NODE_CODE_BLOCK case:
if (node->as.code.info.len == 7 &&
    memcmp(node->as.code.info.data, "mermaid", 7) == 0) {
    // Emit placeholder div with HTML-escaped source
    cmark_strbuf_puts_lit(html, "<div class=\"mermaid-placeholder\" data-mermaid-source=\"");
    escape_html(html, node->as.code.literal.data, node->as.code.literal.len);
    cmark_strbuf_puts_lit(html, "\"><span style=\"color:#999;font-size:0.9em;\">Loading diagram...</span></div>\n");
    // Set hasMermaid flag
} else {
    // existing code block rendering
}
```

### 2. WKWebView Warm Pool

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Custom `WebViewPool` class | N/A (AppKit) | Pre-warm 2-3 WKWebView instances at app launch | WKWebView first init is ~50-80ms; pool amortizes this to zero for 2nd+ file opens |

**Confidence:** MEDIUM (pattern well-established on iOS; verified WKWebView init cost is significant via MDViewer's own signpost data showing 184.50ms total launch-to-paint)

**No new dependencies.** Uses existing `WebKit` framework.

**Key APIs (all macOS 13+):**
- `WKWebView(frame:configuration:)` -- pre-create with shared `WKWebViewConfiguration`
- `WKWebViewConfiguration` -- must be created ONCE and shared (config is immutable after WKWebView init)
- `WKUserContentController` -- message handlers added per-checkout, removed on return to pool

**Architecture:**

```swift
final class WebViewPool {
    static let shared = WebViewPool()
    private var available: [WKWebView] = []
    private let config: WKWebViewConfiguration
    private let poolSize = 2

    init() {
        config = WKWebViewConfiguration()
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
    }

    /// Call from applicationDidFinishLaunching on main thread
    func warmUp() {
        for _ in 0..<poolSize {
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.loadHTMLString("<html></html>", baseURL: nil)
            available.append(wv)
        }
    }

    /// Returns a pre-warmed WKWebView, or creates a new one if pool is empty
    func checkout() -> WKWebView {
        if let wv = available.popLast() { return wv }
        return WKWebView(frame: .zero, configuration: config)
    }

    /// Reset and return to pool. Removes old message handlers.
    func checkin(_ webView: WKWebView) {
        webView.configuration.userContentController
            .removeAllScriptMessageHandlers()
        webView.loadHTMLString("", baseURL: nil)
        if available.count < poolSize {
            available.append(webView)
        }
    }
}
```

**Critical constraint:** `WKProcessPool` is deprecated on macOS 12+ (auto-shared per PROJECT.md). Do NOT create custom process pools.

**Integration with WebContentView:** Currently, `WebContentView.init` creates a WKWebView internally. Change to accept a WKWebView via `init(webView:)` from the pool. On `deinit` or window close, return to pool via `WebViewPool.shared.checkin()`.

### 3. Zero-Copy C-to-Swift String Bridge

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `UnsafeBufferPointer<UInt8>` | Swift 5.9+ | Avoid `String(cString:)` copy from cmark output | `String(cString:)` copies entire buffer; for 500KB HTML this is a measurable allocation |
| `Data(bytesNoCopy:count:deallocator:)` | Foundation | Wrap C buffer without copying | Passes ownership semantics to Swift's ARC |

**Confidence:** MEDIUM (Swift unsafe APIs well-documented; actual performance gain needs profiling)

**Current bottleneck in `MarkdownRenderer.swift` line 127:**
```swift
// This copies the ENTIRE HTML output into a Swift String
return String(cString: htmlCStr)
```

**How the chunked callback eliminates this:** With `cmark_render_html_chunked`, each chunk callback receives `(const char *data, size_t len)` directly from the C `cmark_strbuf`. The Swift callback wrapper can create a String without the full-document copy:

```swift
// Swift callback invoked from C
let callback: @convention(c) (UnsafePointer<CChar>?, Int, Int32, UnsafeMutableRawPointer?) -> Int32 = {
    data, len, isLast, userdata in
    guard let data = data, let ctx = userdata else { return 1 }
    let context = Unmanaged<RenderContext>.fromOpaque(ctx).takeUnretainedValue()

    // Create String from C buffer -- this IS a copy, but only chunk-sized (64KB) not full-doc-sized
    let chunk = String(
        decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(data)), count: len),
        as: UTF8.self
    )
    context.chunks.append(chunk)
    context.hasMermaid = context.hasMermaid || (isLast != 0 && context.mermaidFlag)
    return 0
}
```

**Why full zero-copy to JS is NOT feasible:** `callAsyncJavaScript` serializes arguments through WebKit's IPC layer. The argument MUST be a Swift String (or other serializable type). There is no way to pass an `UnsafeBufferPointer` directly to JavaScript. The optimization is therefore: reduce allocation from one full-document String to N chunk-sized Strings. For a 500KB document with 64KB chunks, this means 8 x 64KB allocations instead of 1 x 500KB -- each individually smaller and freeable earlier.

**Realistic assessment of savings:** The biggest win is not memory size but latency. The first 64KB chunk is available to WKWebView while subsequent chunks are still being rendered from the AST. This is pipelining, not zero-copy.

### 4. Streaming/Incremental cmark Parsing

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `cmark_parser_feed` (existing API) | 0.29.0.gfm.13 | Feed file data incrementally | Already in cmark API; MDViewer currently feeds the entire file as a Swift String |

**Confidence:** LOW for incremental rendering; HIGH for incremental feeding

**What cmark already supports:** `cmark_parser_feed()` accepts chunks of markdown input. You can call it multiple times before `cmark_parser_finish()`. This is useful for avoiding loading the entire file into a single Swift String before parsing.

**What cmark does NOT support (verified from source):**
1. Inline parsing happens ONLY during `cmark_parser_finish()` (see `parser.h` -- the parser struct tracks open blocks but doesn't resolve inlines until finish)
2. Reference link resolution requires the entire document to be scanned (forward references)
3. The AST is not valid until `finish()` returns
4. There is no `cmark_parser_get_completed_blocks()` or similar API

**What IS feasible (no cmark changes):** Feed mapped file data directly to cmark without creating a Swift String first:

```swift
let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
data.withUnsafeBytes { rawBuffer in
    let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
    cmark_parser_feed(parser, ptr, rawBuffer.count)
}
```

This eliminates the current `String(data:encoding:)` allocation (line 69 of MarkdownRenderer.swift).

**Recommendation:** Use `cmark_parser_feed` with mapped Data to eliminate input string allocation. Do NOT attempt incremental AST emission -- the ROI is too low (cmark parsing is <5ms for typical files) and the complexity is very high.

### 5. Native NSTextView Rendering Path

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `NSTextView` | macOS 13+ (AppKit) | Render simple markdown without WKWebView overhead | Eliminates WebKit process spawn and IPC for mermaid-free files |
| Custom cmark AST walker | N/A | Convert cmark AST to NSAttributedString | Apple's `AttributedString(markdown:)` lacks GFM table/tasklist support |

**Confidence:** LOW-MEDIUM (feasibility proven by Markdownosaur/CocoaMarkdown; typography parity is the hard problem)

**Why NOT Apple's `AttributedString(markdown:)`:** It supports CommonMark basics (bold, italic, links, headings, lists) but does NOT support GFM extensions: tables, task lists, strikethrough, autolinks. Since MDViewer's cmark-gfm fork already parses these, the right approach is walking the cmark AST directly.

**What a custom AST-to-NSAttributedString walker looks like:**

```swift
final class NativeMarkdownRenderer {
    func render(root: OpaquePointer /* cmark_node* */) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let iter = cmark_iter_new(root)
        defer { cmark_iter_free(iter) }

        while true {
            let evType = cmark_iter_next(iter)
            if evType == CMARK_EVENT_DONE { break }
            let node = cmark_iter_get_node(iter)!
            let nodeType = cmark_node_get_type(node)

            switch (nodeType, evType) {
            case (CMARK_NODE_PARAGRAPH, CMARK_EVENT_ENTER):
                // push paragraph style
            case (CMARK_NODE_PARAGRAPH, CMARK_EVENT_EXIT):
                result.append(NSAttributedString(string: "\n"))
            case (CMARK_NODE_TEXT, _):
                let text = String(cString: cmark_node_get_literal(node))
                result.append(NSAttributedString(string: text, attributes: currentAttributes))
            // ... ~15 more cases for headings, emphasis, strong, code, links, lists
            default: break
            }
        }
        return result
    }
}
```

**Typography challenges for Latin Modern Roman fidelity:**
- Font setting: `NSFont(name: "Latin Modern Roman", size: 16)` -- requires the `.woff2` fonts to be registered with `CTFontManagerRegisterFontsForURL` (or converted to `.otf`)
- Code blocks: Use `NSTextBlock` subclass (TextKit 2) for background-colored regions
- Tables: `NSTextTable` + `NSTextTableBlock` exist but are poorly documented and visually limited -- this is the biggest fidelity gap vs. WKWebView
- Headings: `NSParagraphStyle` with custom `paragraphSpacingBefore`/`After` and scaled font sizes

**Routing decision (cheap to compute):**

```swift
func shouldUseNativeRenderer(root: OpaquePointer) -> Bool {
    let child = cmark_node_first_child(root)
    var cur = child
    while let node = cur {
        let type = cmark_node_get_type(node)
        // Bail to WKWebView for tables, HTML blocks, or mermaid code blocks
        if type == CMARK_NODE_HTML_BLOCK { return false }
        if cmark_node_get_syntax_extension(node) != nil { return false } // table, etc.
        if type == CMARK_NODE_CODE_BLOCK {
            if let info = cmark_node_get_fence_info(node),
               String(cString: info) == "mermaid" { return false }
        }
        cur = cmark_node_next(node)
    }
    return true
}
```

**Font registration for NSTextView:**
The bundled `.woff2` fonts cannot be used directly with Core Text. Options:
1. Ship `.otf` versions alongside `.woff2` (adds ~200KB to bundle, straightforward)
2. Convert at runtime using a tiny WOFF2 decoder (overengineered)

Recommendation: Ship `.otf` duplicates. Register once at launch:
```swift
if let fontURL = Bundle.main.url(forResource: "lmroman10-regular", withExtension: "otf") {
    CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
}
```

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Markdown parser | Vendored swift-cmark fork | swift-markdown (Apple) | No GFM extensions (tables, autolinks, tasklists); would lose feature parity |
| Chunked rendering | C-level callback in html.c | Swift-side regex splitting (current) | Regex splitting is fragile, adds ~2ms, cannot detect mermaid without second pass |
| Web view pooling | Custom 40-line WebViewPool | Third-party WebViewWarmUper | iOS-focused, unnecessary SPM dependency |
| Native text rendering | Custom cmark AST walker | `AttributedString(markdown:)` | No GFM support; cannot reuse existing cmark AST |
| Native text rendering | NSTextView | STTextView (TextKit 2 replacement) | Unnecessary dependency; NSTextView is sufficient for read-only display |
| Zero-copy bridge | Chunk-sized String copies | Full zero-copy to JS | WKWebView IPC requires serialized strings; true zero-copy is impossible across the process boundary |

## Integration with Existing Codebase

### Files that change:

| File | Change | Reason |
|------|--------|--------|
| `Package.swift` | Point to local `../swift-cmark` path | Vendor the fork |
| `project.yml` | Point to local `../swift-cmark` path | XcodeGen project definition |
| `MarkdownRenderer.swift` | Replace `cmark_render_html_with_mem` call with `cmark_render_html_chunked` callback; remove `chunkHTML()` and `processMermaidBlocks()` methods | Core pipeline change -- ~80 lines removed, ~40 added |
| `WebContentView.swift` | Accept WKWebView from pool via new initializer; return to pool on cleanup | Pool lifecycle integration |
| `AppDelegate.swift` | Initialize WebViewPool on launch; add NSTextView routing logic | Pool warmup + rendering path decision |

### New files:

| File | Purpose |
|------|---------|
| `WebViewPool.swift` | WKWebView warm pool (~50 lines) |
| `NativeTextView.swift` | NSTextView-based rendering for simple documents (~200 lines) |
| `NativeMarkdownRenderer.swift` | cmark AST to NSAttributedString walker (~250 lines) |

### Files in swift-cmark fork that change:

| File | Change | Lines |
|------|--------|-------|
| `src/html.c` | Add `cmark_render_html_chunked` function; modify `S_render_node` CODE_BLOCK case for mermaid | ~80 added |
| `src/include/cmark-gfm.h` | Add callback typedef and `cmark_render_html_chunked` declaration | ~15 added |

### Files that do NOT change:

| File | Reason |
|------|--------|
| `template.html` | Still used for WKWebView path |
| `MarkdownWindow.swift` | Window management unchanged |
| `PDFPrintView.swift` | PDF export unchanged (always uses WKWebView) |
| `main.swift` | Entry point unchanged |
| `mermaid.min.js` | Still loaded on-demand for WKWebView path |

## Priority Order (ROI-based)

1. **Vendored cmark with chunked HTML + mermaid detection** -- Highest impact. Eliminates 3 Swift-side post-processing passes (chunking regex, mermaid regex, entity encode/decode). Enables pipelined first-chunk delivery. Estimated: ~15ms savings on large files, eliminates 2 regex compilations per render.

2. **WKWebView warm pool** -- High impact for 2nd+ file opens. Zero marginal cost after first file. Estimated: ~50-80ms savings per subsequent window. Low implementation effort (~50 lines).

3. **Zero-copy input feeding** -- Feed mapped Data directly to cmark_parser_feed instead of converting to Swift String first. Estimated: ~3-8ms savings on 10MB+ files. Trivial implementation change (~5 lines).

4. **Native NSTextView path** -- Highest potential impact (eliminates WKWebView entirely for simple docs, ~80-120ms savings). But: significant implementation effort (~500 lines), limited to docs without tables/mermaid, requires OTF font variants. Build last, behind a feature flag.

5. **Streaming cmark parsing** -- Defer entirely. cmark parsing is <5ms. The complexity of partial AST emission far exceeds the possible gain.

## Sources

- cmark-gfm source code: `/Users/mit/Documents/GitHub/swift-cmark/` (verified locally, all files read)
- cmark-gfm public API: `src/include/cmark-gfm.h` (896 lines, verified)
- HTML renderer: `src/html.c` (538 lines, verified -- `S_render_node` and `cmark_render_html_with_mem`)
- html_renderer struct: `src/include/render.h` (verified -- includes `opaque` field for callback context)
- Iterator internals: `src/iterator.c` + inline version in `src/include/iterator.h` (verified)
- Node struct: `src/include/node.h` (verified -- `as.code.info` for fence_info access)
- Parser struct: `src/include/parser.h` (verified -- inline parsing only in finish())
- Buffer/Chunk types: `src/include/buffer.h`, `src/include/chunk.h` (verified)
- Extension API: `src/include/cmark-gfm-extension_api.h` (verified -- 740 lines)
- [Apple AttributedString Markdown docs](https://developer.apple.com/documentation/foundation/instantiating-attributed-strings-with-markdown-syntax)
- [Markdownosaur -- AST-to-NSAttributedString](https://github.com/christianselig/Markdownosaur)
- [CocoaMarkdown -- cmark to NSAttributedString](https://github.com/indragiek/CocoaMarkdown)
- [WebViewWarmUper pattern](https://github.com/bernikovich/WebViewWarmUper)
- [Swift zero-copy C API discussion](https://forums.swift.org/t/using-string-with-zero-copy-c-apis/70476)
- [WKWebView memory analysis](https://embrace.io/blog/wkwebview-memory-leaks/)

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Vendored cmark + chunked API | HIGH | Full source code read and verified; modification points identified precisely |
| Mermaid detection in C | HIGH | `node->as.code.info` field verified in node.h; 7-byte memcmp is trivial |
| WKWebView warm pool | MEDIUM | Pattern proven on iOS; macOS-specific timing needs measurement |
| Zero-copy input feeding | HIGH | `Data.withUnsafeBytes` + `cmark_parser_feed` are both stable, well-documented APIs |
| NSTextView rendering path | LOW-MEDIUM | Feasible but typography parity is unproven; table rendering in NSTextTable is a known weak point |
| Streaming incremental parsing | LOW | cmark architecture prevents this without deep, risky changes; correctly deferred |
