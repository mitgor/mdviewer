# Architecture Patterns

**Domain:** Deep rendering optimization for macOS markdown viewer (v2.1)
**Researched:** 2026-04-16

## Current Architecture Snapshot

```
File open
  -> AppDelegate.openFile(url)
       -> DispatchQueue.global: MarkdownRenderer.renderFullPage(fileURL:template:)
            -> Data(contentsOf: url, options: .mappedIfSafe)
            -> parseMarkdownToHTML(markdown)       // cmark-gfm C API
            -> processMermaidBlocks(html)           // regex replace
            -> chunkHTML(processed)                 // regex block-tag split at 64KB
            -> template.prefix + firstChunk + template.suffix
       <- RenderResult(page, remainingChunks, hasMermaid)
  -> DispatchQueue.main: displayResult(result, for:url, paintState:)
       -> WebContentView (pre-warmed or new)
       -> MarkdownWindow(fileURL:, contentView:)
       -> webView.loadHTMLString(page, baseURL: resourceURL)
       -> firstPaint JS message -> injectRemainingChunks() -> loadAndInitMermaid()
```

### Key Components and Their Optimization Impact

| Component | File | Role | Impact |
|-----------|------|------|--------|
| `AppDelegate` | AppDelegate.swift | Orchestrates open-to-paint, owns window array, holds pre-warmed view | MODIFIED: pool manager, routing logic |
| `MarkdownRenderer` | MarkdownRenderer.swift | cmark parse + HTML chunk split | HEAVILY MODIFIED: new chunk API, AST walking |
| `WebContentView` | WebContentView.swift | WKWebView host, chunk injection, JS bridge | MODIFIED: pool-compatible lifecycle |
| `MarkdownWindow` | MarkdownWindow.swift | NSWindow subclass, frame persistence | MODIFIED: dual backend support |
| `SplitTemplate` | MarkdownRenderer.swift | Pre-split HTML template | UNCHANGED for WKWebView path |
| `RenderResult` | MarkdownRenderer.swift | Data transfer object | MODIFIED: streaming variant needed |

---

## Optimization 1: Vendored cmark with Direct-to-Chunk AST Output

### What Changes

**Current:** SPM pulls `swift-cmark` (gfm branch, revision 924936d) as a package dependency. `MarkdownRenderer` calls `cmark_parser_feed` -> `cmark_parser_finish` -> `cmark_render_html_with_mem`, gets a single HTML string, then regex-splits it into chunks via `chunkHTML()`.

**Proposed:** Copy the C source from `/Users/mit/Documents/GitHub/swift-cmark/` directly into the Xcode project as static library targets. Add a new C function `cmark_render_html_chunked()` that uses the existing iterator pattern but emits HTML in block-boundary chunks instead of one monolithic string.

### Source Structure to Vendor

The swift-cmark repo has two compilation targets:

**cmark-gfm** (core library) -- `src/` directory:
- ~20 `.c` files (arena.c, blocks.c, buffer.c, cmark.c, cmark_ctype.c, commonmark.c, footnotes.c, houdini_href_e.c, houdini_html_e.c, houdini_html_u.c, html.c, inlines.c, iterator.c, latex.c, linked_list.c, man.c, map.c, node.c, plaintext.c, plugin.c, references.c, registry.c, render.c, scanners.c, syntax_extension.c, utf8.c)
- 2 `.inc` files (case_fold_switch.inc, entities.inc) -- included by source files
- 25 headers in `src/include/` including `module.modulemap`

**cmark-gfm-extensions** -- `extensions/` directory:
- 7 `.c` files (autolink.c, core-extensions.c, ext_scanners.c, strikethrough.c, table.c, tagfilter.c, tasklist.c)
- 4 `.h` files (private headers)
- 1 public header + modulemap in `extensions/include/`

### Build System Integration

**In `project.yml`:**

```yaml
targets:
  cmark-gfm:
    type: library.static
    platform: macOS
    sources:
      - Vendor/cmark-gfm/src
    settings:
      HEADER_SEARCH_PATHS:
        - $(SRCROOT)/Vendor/cmark-gfm/src/include
        - $(SRCROOT)/Vendor/cmark-gfm/extensions/include
      MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/src/include/module.modulemap
    excludes:
      - "*.re"
      - "*.in"
      - CMakeLists.txt

  cmark-gfm-extensions:
    type: library.static
    platform: macOS
    sources:
      - Vendor/cmark-gfm/extensions
    settings:
      HEADER_SEARCH_PATHS:
        - $(SRCROOT)/Vendor/cmark-gfm/src/include
        - $(SRCROOT)/Vendor/cmark-gfm/extensions/include
      MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/extensions/include/module.modulemap
    dependencies:
      - target: cmark-gfm
    excludes:
      - "*.re"
      - CMakeLists.txt

  MDViewer:
    # ... existing config ...
    dependencies:
      - target: cmark-gfm
      - target: cmark-gfm-extensions
    # REMOVE: package dependencies for swift-cmark
```

**Directory layout:**
```
MDViewer/
  Vendor/
    cmark-gfm/
      src/           <- copy from swift-cmark/src/
        include/     <- headers + modulemap
        *.c, *.inc
      extensions/    <- copy from swift-cmark/extensions/
        include/     <- header + modulemap
        *.c, *.h
```

### New C API: Chunked HTML Rendering

The existing `cmark_render_html_with_mem()` in `html.c` (line 505) uses an iterator loop over AST nodes, calling `S_render_node()` for each. Top-level block nodes are natural chunk boundaries -- the iterator already visits them in document order.

**New function to add to `html.c`:**

```c
// Callback receives each chunk as it's produced
typedef void (*cmark_chunk_callback)(const char *html, size_t len, int has_mermaid, void *userdata);

void cmark_render_html_chunked(
    cmark_node *root,
    int options,
    cmark_llist *extensions,
    cmark_mem *mem,
    size_t chunk_byte_limit,
    cmark_chunk_callback callback,
    void *userdata
);
```

Implementation approach: walk the AST with the same iterator, but flush the `cmark_strbuf` at top-level block boundaries when accumulated bytes exceed `chunk_byte_limit`. Each flush invokes the callback. During iteration, inspect code blocks for `language-mermaid` info strings to set the `has_mermaid` flag -- eliminating the regex-based `processMermaidBlocks()`.

This eliminates:
1. The monolithic HTML string allocation from `cmark_render_html_with_mem`
2. The regex-based `chunkHTML()` post-processing in Swift
3. The `processMermaidBlocks()` regex pass (mermaid detection moves to AST node type inspection)
4. The `encodeHTMLEntities` / `decodeHTMLEntities` character loops (mermaid placeholders generated directly in C)

### Impact on MarkdownRenderer

`parseMarkdownToHTML()`, `chunkHTML()`, and `processMermaidBlocks()` merge into a single call path:

```swift
func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
    // Create parser, feed, finish (same as before)
    // NEW: call cmark_render_html_chunked with callback
    // Callback appends each chunk to a Swift array
    // hasMermaid set by callback's has_mermaid parameter
}
```

**Files modified:** `project.yml` (replace SPM with static lib targets), `MarkdownRenderer.swift` (heavy rewrite of render methods), `html.c` (new chunked function), `cmark-gfm.h` (new declaration)
**Files added:** `Vendor/cmark-gfm/` (entire directory tree)
**Files removed:** SPM package references in `project.yml`

### Module Import Compatibility

Currently Swift imports `cmark_gfm` and `cmark_gfm_extensions` as module names via SPM. The existing modulemaps already define `module cmark_gfm` and `module cmark_gfm_extensions`. As long as vendored targets use these same modulemaps, all `import` statements in `MarkdownRenderer.swift` remain unchanged.

---

## Optimization 2: WKWebView Warm Pool

### What Changes

**Current:** `AppDelegate` pre-warms exactly one `WebContentView` at launch (`preWarmedContentView`). First file gets it; subsequent files create new `WebContentView` on-demand, paying ~40ms WKWebView init cost.

**Proposed:** Pool of 2-3 pre-warmed `WebContentView` instances, replenished after each use.

### New Component: `WebViewPool`

```swift
final class WebViewPool {
    private var available: [WebContentView] = []
    private let targetSize: Int

    init(size: Int = 2) {
        self.targetSize = size
        replenish()
    }

    func acquire() -> WebContentView {
        if let view = available.popLast() {
            replenishIfNeeded()
            return view
        }
        return WebContentView(frame: .zero)  // fallback if pool exhausted
    }

    private func replenishIfNeeded() {
        if available.count < targetSize {
            DispatchQueue.main.async { [weak self] in
                self?.replenish()
            }
        }
    }

    private func replenish() {
        while available.count < targetSize {
            available.append(WebContentView(frame: .zero))
        }
    }
}
```

### Integration with AppDelegate

```diff
- private var preWarmedContentView: WebContentView?
+ private let webViewPool = WebViewPool(size: 2)

  private func displayResult(...) {
-     let contentView: WebContentView
-     if let preWarmed = preWarmedContentView {
-         contentView = preWarmed
-         preWarmedContentView = nil
-     } else {
-         contentView = WebContentView(frame: .zero)
-     }
+     let contentView = webViewPool.acquire()
      contentView.delegate = self
      // ... rest unchanged
  }
```

Pool creates fresh views asynchronously after each acquisition. Not a recycling pool -- used views are deallocated normally with their window. This avoids WKWebView process state cleanup issues.

**Files modified:** `AppDelegate.swift` (replace pre-warm with pool)
**Files added:** `WebViewPool.swift`

---

## Optimization 3: Streaming Parse Pipeline

### What Changes

**Current flow (batch):**
```
background: read file -> parse all -> chunk all -> return RenderResult
main:       loadContent(page, remainingChunks, hasMermaid)
```

**Proposed flow (streaming):**
```
background: read file -> create parser -> feed all data -> finish
            -> chunked callback fires per block boundary:
               chunk 0 -> main: loadHTMLString(template.prefix + chunk0 + template.suffix)
               chunk 1 -> main: appendChunk(chunk1) via callAsyncJavaScript
               chunk 2 -> main: appendChunk(chunk2) via callAsyncJavaScript
            -> finish -> main: initMermaid() if needed
```

First chunk arrives at the UI before later chunks are rendered to HTML.

### New Protocol: `StreamingRenderDelegate`

```swift
protocol StreamingRenderDelegate: AnyObject {
    func renderer(_ renderer: MarkdownRenderer, didProduceFirstChunk html: String)
    func renderer(_ renderer: MarkdownRenderer, didProduceChunk html: String, index: Int)
    func rendererDidFinish(_ renderer: MarkdownRenderer, hasMermaid: Bool)
}
```

### Integration Complexity

This is the **hardest optimization** because it restructures the core data flow:

1. **Template wrapping on first chunk only.** The first callback must wrap in `template.prefix + chunk + template.suffix`. Subsequent callbacks inject via `appendChunk`. This means the template must be accessible in the callback context.

2. **WebContentView streaming input.** Currently `loadContent()` accepts the full page + all remaining chunks at once. Streaming requires a `loadFirstPage(html:)` method followed by individual `appendChunk(html:)` calls dispatched to main thread.

3. **Mermaid detection timing.** With AST-level detection in the chunked renderer, a mermaid code block might appear in any chunk. Options:
   - Defer mermaid init until rendering completes (current behavior, safe, recommended)
   - Quick pre-scan for `` ```mermaid `` in raw markdown text before parsing (cheap string search)

4. **Cross-thread coordination.** Chunks are produced on the background queue but must be dispatched to main thread for WKWebView. The first chunk must arrive and trigger `loadHTMLString` before subsequent chunks can be injected (WKWebView must have loaded the page first). Need a serial dispatch chain or semaphore coordination.

### Dependency

Requires the chunked callback API from Optimization 1. Without it, streaming means regex-chunking partial HTML, which is fragile and defeats the purpose.

**Files modified:** `MarkdownRenderer.swift` (new streaming render path), `WebContentView.swift` (streaming input methods), `AppDelegate.swift` (new flow orchestration)

---

## Optimization 4: Zero-Copy C-to-JS String Bridge

### Realistic Assessment

After examining the data path:

```
cmark C buffer (cmark_strbuf, UTF-8 bytes)
  -> String(cString: htmlCStr)            // copy 1: C -> Swift heap
  -> template.prefix + chunk + suffix     // copy 2: concatenation
  -> webView.loadHTMLString(page)         // copy 3: IPC to WebProcess (unavoidable)
```

**Copy 1** (`String(cString:)`) is ~0.1ms for 64KB -- negligible.
**Copy 2** (concatenation) can be avoided with buffer reuse.
**Copy 3** (WKWebView IPC) is unavoidable -- `loadHTMLString` and `callAsyncJavaScript` both require `String` and serialize to the WebProcess.

### Practical Optimization: Buffer Reuse

Instead of allocating a new string per render for template concatenation:

```swift
// In MarkdownRenderer or a dedicated buffer
private var pageBuffer = ""

func buildPage(template: SplitTemplate, firstChunk: String) -> String {
    pageBuffer.removeAll(keepingCapacity: true)
    pageBuffer.reserveCapacity(template.prefix.count + firstChunk.count + template.suffix.count)
    pageBuffer.append(template.prefix)
    pageBuffer.append(firstChunk)
    pageBuffer.append(template.suffix)
    return pageBuffer
}
```

### Where Zero-Copy Actually Matters: NSTextView Path

For Optimization 5, `NSAttributedString` can be built directly from C string data without Swift String intermediaries, using `CFAttributedString` with data pointers. This is where zero-copy provides real value -- no WKWebView IPC involved.

**Verdict:** Minor standalone optimization. Fold buffer reuse into Optimization 1, and C-to-attributed-string bridging into Optimization 5. Not a separate phase.

**Files modified:** `MarkdownRenderer.swift` (buffer reuse in renderFullPage)

---

## Optimization 5: Dual Rendering Backend (NSTextView vs WKWebView)

### What Changes

**Current:** All files render through WKWebView regardless of content complexity.

**Proposed:** Route simple files (no mermaid, no tables) to native `NSTextView` with `NSAttributedString`, bypassing WKWebView entirely.

### Architecture: Rendering Backend Protocol

```swift
protocol RenderingBackend: NSView {
    var renderDelegate: RenderingBackendDelegate? { get set }
    func loadRenderedContent(_ content: RenderedContent)
    func toggleMonospace()
    func printContent(title: String)
    func exportPDF(filename: String)
}

protocol RenderingBackendDelegate: AnyObject {
    func backendDidFinishFirstPaint(_ backend: RenderingBackend)
}

enum RenderedContent {
    case html(page: String, remainingChunks: [String], hasMermaid: Bool)
    case attributedString(NSAttributedString)
}
```

### New Component: `NativeTextView`

An `NSView` subclass wrapping `NSScrollView` + `NSTextView`:

```swift
final class NativeTextView: NSView, RenderingBackend {
    private let scrollView: NSScrollView
    private let textView: NSTextView
    weak var renderDelegate: RenderingBackendDelegate?

    func loadRenderedContent(_ content: RenderedContent) {
        guard case .attributedString(let attrStr) = content else { return }
        textView.textStorage?.setAttributedString(attrStr)
        // NSTextView renders synchronously -- no async paint callback needed
        renderDelegate?.backendDidFinishFirstPaint(self)
    }

    func printContent(title: String) {
        // NSTextView supports native printing -- no PDF workaround needed
        let printOp = NSPrintOperation(view: textView)
        printOp.run()
    }
}
```

### MarkdownRenderer: AST-to-NSAttributedString

New rendering path that walks the cmark AST and builds `NSAttributedString` directly:

```swift
func renderAttributedString(markdown: String) -> (NSAttributedString, Bool, Bool) {
    // Parse with cmark (same parser setup)
    // Walk AST via cmark_iter_new / cmark_iter_next
    // Map node types to font/paragraph attributes
    // Return (attributedString, hasMermaid, hasTables)
}
```

Node type mapping:

| cmark Node Type | NSAttributedString Treatment |
|-----------------|------------------------------|
| HEADING (h1-h6) | Latin Modern Roman bold, scaled size |
| PARAGRAPH | Default paragraph style, Latin Modern Roman regular |
| STRONG | Bold font trait |
| EMPH | Italic font trait |
| CODE | Latin Modern Mono regular |
| CODE_BLOCK | Mono font + light gray background (via paragraph background) |
| LINK | `.link` attribute with URL |
| LIST/ITEM | Paragraph head indent + tab stops |
| TABLE | **Not supported** -- route to WKWebView |
| THEMATIC_BREAK | Paragraph border or thin view |

### Routing Logic

In `AppDelegate.displayResult()`:

```swift
if result.hasMermaid || result.hasTables {
    // WKWebView path (existing, with pool)
    let webView = webViewPool.acquire()
    // ...
} else {
    // Native text path (new)
    let textView = NativeTextView(frame: .zero)
    // ...
}
```

`RenderResult` needs a `hasTables: Bool` field, detected during AST walking in Optimization 1's chunked renderer.

### MarkdownWindow Changes

```diff
- let contentViewWrapper: WebContentView
+ let contentViewWrapper: RenderingBackend
```

Menu actions (`toggleMonospace`, `printContent`, `exportPDF`) already call through methods defined on the protocol, so AppDelegate menu handlers work unchanged.

### PDF/Print Simplification

`NativeTextView` uses standard `NSPrintOperation(view:)` -- no `createPDF` + `PDFPrintView` workaround needed. This is actually simpler than the WKWebView path.

**Files modified:** `MarkdownWindow.swift` (protocol-typed content view), `AppDelegate.swift` (routing, backend delegate), `MarkdownRenderer.swift` (attributed string rendering), `WebContentView.swift` (conform to protocol)
**Files added:** `NativeTextView.swift`, `RenderingBackend.swift`

---

## Component Dependency Graph

```
Optimization 1 (Vendored cmark + chunked API)    Optimization 2 (WKWebView pool)
    |                                                  |
    +---> Optimization 3 (Streaming pipeline)          | (independent)
    |     requires chunked callback API                |
    |                                                  |
    +---> Optimization 5 (NSTextView backend)          |
    |     requires AST walking for attr string         |
    |     requires hasTables detection                 |
    |                                                  |
    +---> Optimization 4 (Zero-copy)                   |
          folded into 1 (buffer reuse)                 |
          and 5 (C-to-attrstring)                      |
```

## Recommended Build Order

### Phase 1: Vendored cmark + Chunked API
**Rationale:** Foundation for all other optimizations. Most isolated change initially (build system swap with no behavior change, then new API).

Steps:
1. Copy swift-cmark sources into `Vendor/cmark-gfm/`
2. Add static library targets to `project.yml`, remove SPM dependency
3. Verify existing tests pass with no behavior change
4. Add `cmark_render_html_chunked()` to `html.c` with callback API
5. Add mermaid detection via AST node inspection (code block info string check)
6. Update `MarkdownRenderer` to use chunked API
7. Remove `chunkHTML()`, `processMermaidBlocks()`, `encodeHTMLEntities()`, `decodeHTMLEntities()` regex methods
8. Add buffer reuse for template concatenation (Optimization 4 folded in)

Files changed: `project.yml`, `MarkdownRenderer.swift`, `html.c`, `cmark-gfm.h`
Files added: `Vendor/cmark-gfm/` directory tree

### Phase 2: WKWebView Warm Pool
**Rationale:** Independent of Phase 1, low risk, immediate measurable impact on 2nd+ file opens.

Steps:
1. Create `WebViewPool.swift`
2. Replace `preWarmedContentView` in `AppDelegate` with pool
3. Verify multi-file open timing improvement with Instruments

Files changed: `AppDelegate.swift`
Files added: `WebViewPool.swift`

### Phase 3: Streaming Pipeline
**Rationale:** Depends on Phase 1's chunked callback API. Changes the core data flow -- most risk.

Steps:
1. Add `StreamingRenderDelegate` protocol
2. Implement streaming render path in `MarkdownRenderer`
3. Add streaming input methods to `WebContentView`
4. Update `AppDelegate.openFile()` to use streaming flow
5. Handle cross-thread chunk dispatch (background produce -> main consume)
6. Verify first-paint timing improvement

Files changed: `MarkdownRenderer.swift`, `WebContentView.swift`, `AppDelegate.swift`

### Phase 4: Dual Rendering Backend (NSTextView)
**Rationale:** Most complex, most new code. Depends on Phase 1 (AST walking). Last because it adds a new rendering path that needs thorough testing.

Steps:
1. Define `RenderingBackend` protocol based on `WebContentView`'s public API
2. Conform `WebContentView` to protocol
3. Implement `NativeTextView` with NSScrollView + NSTextView
4. Add `renderAttributedString()` to `MarkdownRenderer` (AST -> NSAttributedString)
5. Add `hasTables` detection to render result
6. Add routing logic to `AppDelegate.displayResult()`
7. Update `MarkdownWindow` to use protocol-typed content view
8. Verify print/export works on both backends
9. Style matching: ensure NSTextView output matches WKWebView typography (Latin Modern fonts, spacing)

Files changed: `MarkdownWindow.swift`, `AppDelegate.swift`, `MarkdownRenderer.swift`, `WebContentView.swift`
Files added: `NativeTextView.swift`, `RenderingBackend.swift`

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Recycling WKWebView Instances
**What:** Returning used WKWebView instances to the pool after window close.
**Why bad:** WKWebView retains process state, cached resources, and JS context. "Resetting" via `loadHTMLString("")` is unreliable -- memory leaks accumulate.
**Instead:** Pre-create fresh instances. Let used instances deallocate with their window.

### Anti-Pattern 2: Streaming via Repeated cmark_parser_finish
**What:** Feed partial file data, call `cmark_parser_finish` repeatedly for incremental AST output.
**Why bad:** `cmark_parser_finish` finalizes the AST. Calling it on partial input produces incorrect parse results (broken block structures, unclosed lists). The cmark parser is designed for feed-all-then-finish.
**Instead:** Feed all data, finish once, then stream the **rendering** of the complete AST via the chunked callback. The streaming is in rendering, not parsing.

### Anti-Pattern 3: NSAttributedString from HTML
**What:** Use `NSAttributedString(html:)` to convert cmark's HTML output for NSTextView.
**Why bad:** `NSAttributedString(html:)` internally creates a WebKit instance. You'd be using WebKit anyway but with less control and worse performance.
**Instead:** Walk the cmark AST directly, building `NSMutableAttributedString` node by node with no HTML intermediate.

### Anti-Pattern 4: Abstracting Too Early
**What:** Create the `RenderingBackend` protocol before implementing `NativeTextView`.
**Why bad:** Protocol design without a concrete second implementation leads to wrong abstractions.
**Instead:** Build `NativeTextView` as concrete class first, then extract the protocol from the actual shared interface.

### Anti-Pattern 5: Shared WKProcessPool
**What:** Create a `WKProcessPool` to share web processes across views.
**Why bad:** `WKProcessPool` is deprecated on macOS 12+ (auto-shared). Already noted in PROJECT.md context section.
**Instead:** Let WebKit manage process sharing automatically.

---

## Scalability Considerations

| Concern | Current (1 pre-warmed) | With Pool (2-3) | With NSTextView |
|---------|----------------------|-----------------|-----------------|
| Memory at idle | ~45MB (1 WebProcess) | ~90MB (2 WebProcesses) | ~15MB (no WebProcess for simple files) |
| 2nd file open latency | ~40ms WKWebView init | ~0ms (pooled) | ~0ms (no WKWebView needed) |
| 10 files open | 10 WebProcesses | 10 WebProcesses | Mixed: only mermaid/table files use WebProcess |
| Large file (10MB) | ~180ms total | ~180ms (pool helps init, not parse) | ~150ms (no IPC overhead) |

## Sources

- swift-cmark source: `/Users/mit/Documents/GitHub/swift-cmark/` (examined directly)
- cmark API headers: `src/include/cmark-gfm.h` -- parser feed/finish, iterator, HTML render APIs
- cmark HTML renderer: `src/html.c` lines 505-538 -- `cmark_render_html_with_mem()` uses iterator + `cmark_strbuf`
- cmark html_renderer struct: `src/include/render.h` lines 37-48 -- `cmark_strbuf *html` accumulation buffer
- cmark module maps: `src/include/module.modulemap`, `extensions/include/module.modulemap`
- MDViewer current code: `AppDelegate.swift`, `MarkdownRenderer.swift`, `WebContentView.swift`, `MarkdownWindow.swift`
- XcodeGen project: `project.yml`
- PROJECT.md context: WKProcessPool deprecated note, current measurements

---

*Architecture research for v2.1 deep optimization: 2026-04-16*
