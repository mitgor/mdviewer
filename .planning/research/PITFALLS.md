# Domain Pitfalls: v2.1 Deep Optimization

**Domain:** Deep rendering optimization for native macOS markdown viewer
**Researched:** 2026-04-16
**Project:** MDViewer v2.1 -- vendored cmark, WKWebView pooling, streaming parse, zero-copy bridge, dual backend

---

## Critical Pitfalls

Mistakes that cause rewrites, crashes, or architectural dead ends.

---

### Pitfall 1: cmark Has No Partial AST Access -- "Streaming Parse" Cannot Emit HTML Incrementally

**What goes wrong:** The planned "streaming parse pipeline with early first-screen emit" assumes you can feed chunks to `cmark_parser_feed()` and render intermediate HTML before `cmark_parser_finish()` is called. This is impossible. cmark's API requires `cmark_parser_finish()` to produce ANY AST nodes. There is no `cmark_parser_get_root()` or equivalent for mid-parse access. The "streaming" API only means you can feed input incrementally to avoid loading the entire file into memory at once -- it does NOT mean you can render incrementally.

**Why it happens:** The cmark streaming API name is misleading. `cmark_parser_feed()` accumulates input internally but does not expose intermediate state. The parser builds an internal representation that is only finalized and accessible after `cmark_parser_finish()`. Furthermore, `cmark_parser_finish()` is terminal -- you cannot continue feeding after calling it.

**Consequences:** If the phase plan assumes "feed 4KB, render first screen, feed rest, render remainder," the entire architecture is wrong. The pipeline must be redesigned around cmark's actual semantics.

**Prevention:**
- Accept that cmark parse is atomic: feed all input, finish, then render.
- For early first-screen emit, use one of these strategies:
  - **Split-input approach:** Detect markdown block boundaries in raw text (blank lines between paragraphs), parse the first N KB as a standalone document, display it, then parse the full document and replace. Risk: the "first screen" parse may differ from the full parse (context-dependent constructs like reference links).
  - **AST-walk approach (recommended):** Feed all input, finish, then walk the AST using `cmark_iter_new()` / `cmark_iter_next()` and render only the first N nodes for first paint. Render remaining nodes afterward. This is what the vendored fork should enable (direct AST-to-chunk output).
- Do NOT attempt to call `cmark_parser_finish()` on a partially-fed parser and then continue feeding -- `finish` is terminal.
- Do NOT create multiple parsers for the same document to simulate streaming -- the overhead of re-parsing eliminates any time savings.

**Detection:** Any design doc that shows "feed chunk -> render chunk -> feed next chunk" is fundamentally wrong. The correct flow is "feed all -> finish -> walk AST -> render in chunks."

**Confidence:** HIGH (verified via cmark.h API documentation and cmark man pages)

---

### Pitfall 2: WKWebView Reuse After Process Termination Produces Permanent Blank Screens

**What goes wrong:** When a pooled WKWebView's WebContent process is terminated by the OS (memory pressure, backgrounding, idle timeout), calling `loadHTMLString` on the same instance may render nothing. The DOM inspector shows new content loaded, but the screen stays white. `reload()` also fails to recover in the pre-render termination case. The only fix is full WKWebView recreation.

**Why it happens:** WKWebView spawns a separate WebContent process per the multi-process WebKit architecture. macOS can kill this process under memory pressure or after extended idle time. The WKWebView object survives in your app's process (no crash), but its rendering pipeline is broken. The `webViewWebContentProcessDidTerminate` delegate callback fires for post-render kills, but may not fire reliably for pre-render kills (the process dies before the view hierarchy fully connects).

**Consequences:** A pre-warmed pool of 2-3 WKWebViews sits in memory. If the OS terminates their WebContent processes before they are used, the pool contains dead views. Files opened with dead pooled views show blank windows with no error indication. Users see a blank app and think it is broken.

**Prevention:**
- Implement `WKNavigationDelegate` on ALL pooled views and handle `webViewWebContentProcessDidTerminate` by immediately removing the terminated view from the pool and creating a fresh replacement.
- Add a health check before dequeuing from pool: load a minimal `<html><body></body></html>` and verify completion via the navigation delegate. If the callback does not fire within 100ms, discard and recreate.
- Set a maximum pool age -- discard and recreate views that have been sitting idle for more than 30 seconds. WebKit processes can be killed silently during extended idle periods.
- Keep pool size to 1 (not 2-3). Each WKWebView spawns 2 extra OS processes (content + networking). 3 pooled views = 7 OS processes and ~150-600MB memory before any file is opened. This is disproportionate for a lightweight viewer.

**Detection:** Debug with `print` in `webViewWebContentProcessDidTerminate` to see if pooled views are dying. Test by opening Activity Monitor, force-killing the "com.apple.WebKit.WebContent" process associated with MDViewer, then opening a file. If the window is blank, the pool lacks recovery logic.

**Confidence:** HIGH (verified via WebKit bug tracker #176855, Apple Developer Forums, Embrace.io analysis, and independent reports from nevermeant.dev)

---

### Pitfall 3: Zero-Copy C-to-Swift String Bridging Creates Dangling Pointers Under ARC

**What goes wrong:** When cmark returns `char*` from `cmark_render_html`, the current code does `String(cString: htmlCStr)` which copies bytes into a Swift-managed String (safe). A zero-copy approach would use `String(bytesNoCopy:length:encoding:freeWhenDone:)` or hold an `UnsafeBufferPointer` to the C memory. If the C memory is freed (via `defer { free(htmlCStr) }`) before all Swift consumers finish using the pointer, you get a dangling pointer -- silent memory corruption, not a crash.

**Why it happens:** Swift's ARC does not track C-allocated memory. The `defer { free(htmlCStr) }` pattern fires at scope exit regardless of whether Swift code still holds a reference to a zero-copy view of that memory. `UnsafeBufferPointer` and `UnsafePointer` are not reference-counted. An invalid pointer looks identical to a valid one -- there is no runtime detection.

**Consequences:** Intermittent corruption of rendered HTML. May produce garbled text, partial content, or (rarely) a crash. Extremely difficult to reproduce and debug because it depends on memory reuse timing. A release build may work for months before a specific allocation pattern triggers corruption.

**Prevention:**
- If using zero-copy, the C memory lifetime MUST outlive ALL Swift consumers. Transfer ownership: do NOT free in `defer`.
- Use `Data(bytesNoCopy:count:deallocator: .custom { ptr, _ in free(ptr) })` to wrap the C memory in a Swift-managed Data object. The custom deallocator calls `free()` only when the Data is deallocated by ARC. This is safe only if cmark used `malloc` (verify: `cmark_render_html_with_mem` uses the allocator you pass -- `cmark_get_default_mem_allocator()` uses malloc).
- NEVER let an `UnsafeBufferPointer` or `UnsafeRawPointer` escape a `withUnsafe*` closure. The pointer is only valid for the closure's duration.
- For the C-to-JS bridge specifically: the real bottleneck is NOT the C-to-Swift copy (sub-millisecond for typical documents). It is the Swift-to-WebKit IPC boundary. `callAsyncJavaScript` with typed arguments (already in use) is already near-optimal. Measure before adding unsafe code.

**Detection:** Run ALL development and CI builds with Address Sanitizer (ASan) enabled. ASan catches use-after-free immediately with a clear stack trace. Also test with Guard Malloc (`MallocGuardEdges=1`) for additional coverage.

**Confidence:** HIGH (Swift unsafe pointer semantics documented at WWDC20 "Unsafe Swift" and Apple developer documentation)

---

### Pitfall 4: NSTextView Cannot Render GFM Tables, Task Lists, or Custom Typography -- Feature Parity Is Impossible

**What goes wrong:** The plan for "Native NSTextView rendering for mermaid-free files" assumes NSTextView + NSAttributedString can render the same GFM content that WKWebView currently handles. It cannot. NSAttributedString's built-in Markdown support (macOS 13+, `AttributedString(markdown:)`) covers ONLY: bold, italic, inline code, strikethrough, and links. It does NOT support:

- Tables (GFM extension)
- Task list checkboxes (GFM extension)
- Heading styles (H1-H6 sizing and spacing)
- Fenced code blocks with background styling
- Block quotes with styled borders/backgrounds
- Horizontal rules
- Any custom CSS (the LaTeX-inspired Latin Modern Roman typography, spacing, colors)

**Why it happens:** NSAttributedString's Markdown initializer uses Apple's Swift Markdown parser, which has basic inline-only output capabilities. NSTextView is a text layout engine, not an HTML/CSS renderer. Reproducing the LaTeX-inspired typography would require building a complete markdown-to-NSAttributedString renderer with custom `NSParagraphStyle`, `NSTextTable` for tables, text attachments for checkboxes, and manual font/spacing calculations.

**Consequences:** Either: (a) the NSTextView path renders a visually degraded document (system fonts instead of Latin Modern, no tables, no task lists, no styled blocks), creating a jarring quality difference between "simple" and "complex" documents, or (b) weeks are spent building a custom renderer that still cannot achieve visual parity, creating permanent code duplication and a maintenance burden of keeping two renderers synchronized.

**Prevention:**
- Scope the NSTextView backend EXTREMELY narrowly: only plain paragraphs, headings, bold, italic, links, and simple lists. NO tables, NO task lists, NO code fences, NO block quotes.
- Implement a "simple document" detector in the renderer that checks the cmark AST for unsupported node types. If any are found, fall back to WKWebView immediately.
- Accept that the NSTextView path will look different -- do NOT attempt pixel-perfect parity. Use system fonts and basic styling. Position this as a "fast preview" mode, not the primary renderer.
- MEASURE FIRST: the current app achieves 184.50ms on M4 Max. Profile where time is spent. If the bottleneck is WKWebView process setup (~80ms), NSTextView eliminates that. If the bottleneck is HTML parsing by WebKit (unlikely for small docs), NSTextView helps. If the bottleneck is template concatenation and JS injection, neither helps. Do not build a dual backend without evidence that it addresses the actual bottleneck.
- Consider deferring to a future milestone. The risk/reward ratio is poor compared to the other optimizations.

**Detection:** Side-by-side screenshot comparison of the same document in both backends. Any visual difference in supported features is a bug report from users.

**Confidence:** HIGH (NSAttributedString markdown limitations are documented by Apple; verified via multiple developer reports)

---

## Moderate Pitfalls

### Pitfall 5: Vendored cmark Fork Drifts From Upstream, Accumulating Security and Compatibility Debt

**What goes wrong:** Forking apple/swift-cmark to add "direct-to-chunk AST output" creates a permanent maintenance burden. The upstream repository receives security fixes, CommonMark spec updates, and Swift toolchain compatibility patches. A vendored fork must manually cherry-pick these changes, resolving conflicts with custom AST walking code.

**Why it happens:** The fork adds new rendering functions that walk the AST and emit chunked HTML. If these functions modify existing cmark source files (the renderer, the iterator, the node types), merge conflicts with upstream changes are inevitable.

**Prevention:**
- Minimize fork surface: add NEW files for chunked rendering. Do NOT modify existing cmark `.c` or `.h` files.
- Use cmark's public AST walking API (`cmark_node_first_child`, `cmark_iter_new`, `cmark_iter_next`, `cmark_node_get_type`) to build chunked output as an external consumer layer on top of the unmodified parser and AST.
- Write the chunked renderer in Swift, calling cmark's C API through the existing Swift module map. This keeps all custom code in Swift (easy to maintain) and the C library untouched (easy to update).
- Pin to a specific upstream commit and document it. Schedule quarterly upstream merge reviews.
- Write regression tests: chunked output concatenated must equal `cmark_render_html` output for the same input, byte-for-byte.

**Detection:** Automated CI job that: (1) checks if upstream has new commits since the pinned revision, (2) runs the CommonMark spec test suite against the fork.

**Confidence:** MEDIUM (fork maintenance is a well-known pattern; severity depends on how invasively the fork modifies cmark internals)

---

### Pitfall 6: WKWebView Pool State Leakage Between Document Loads

**What goes wrong:** Reusing a pooled WKWebView with `loadHTMLString` does not fully reset JavaScript state. Global JS variables (`window.mermaidInitialized`, monospace toggle state), event listeners, and cached DOM references from the previous document persist into the next load. The second document opened in a reused view may behave differently from a fresh view.

**Why it happens:** `loadHTMLString` replaces page content and starts a new navigation, but WebKit may cache some execution context state across navigations within the same web view instance for performance. This behavior varies between WebKit versions and is not consistently documented.

**Consequences:** Mermaid diagrams fail to initialize (previous init state says "already done"). Monospace toggle is stuck in the previous document's state. Chunk injection targets a stale DOM container.

**Prevention:**
- Add a `prepareForReuse()` method to `WebContentView` that:
  1. Calls `loadHTMLString("about:blank", baseURL: nil)` to force a clean navigation
  2. Removes and re-adds script message handlers on the `WKUserContentController`
  3. Resets all Swift-side state: `remainingChunks = []`, `hasMermaid = false`, `isMonospace = false`, `hasProcessedFirstPaint = false`
- Call `prepareForReuse()` before returning a view from the pool
- Wait for the "about:blank" load to complete (via navigation delegate) before loading real content

**Detection:** Open file A (with mermaid), close it, open file B (without mermaid) in the same pooled view. Check WebKit inspector console for mermaid-related errors. Then reverse: open simple file, close, open mermaid file -- verify diagrams render.

**Confidence:** MEDIUM (behavior varies by WebKit version; needs empirical testing on macOS 13-15)

---

### Pitfall 7: Dual Backend Creates Behavioral Divergence Beyond Rendering

**What goes wrong:** Beyond visual parity (Pitfall 4), the NSTextView and WKWebView backends have fundamentally different interaction models: scrolling physics, text selection format (rich text vs. HTML), copy-paste output, find-in-page implementation (NSTextFinder vs. WKWebView built-in), print/PDF export pipeline, and accessibility tree structure. Every user-facing behavior must be tested and potentially reimplemented for each backend.

**Why it happens:** NSTextView and WKWebView are completely different technology stacks built on different frameworks (TextKit vs. WebKit). They share zero rendering or interaction code.

**Consequences:** Users report bugs like "copy-paste gives different output for the same file depending on whether it has a table." PDF export works for WKWebView files but crashes for NSTextView files. Find-in-page (Cmd+F) behaves differently or does not work at all in the NSTextView path.

**Prevention:**
- Do NOT implement print/PDF export for NSTextView. Fall back to WKWebView for export (create a WKWebView on-demand, render, export, destroy).
- Define a common abstraction protocol that both backends conform to, with explicit documentation of which operations are backend-specific.
- Treat the NSTextView backend as a fast-preview mode. If the user triggers any advanced operation (print, export, mermaid, find), transparently swap to WKWebView.
- Consider: is the complexity worth the gain? Current pre-warm saves ~40ms. If remaining WKWebView overhead is 60-80ms for process setup, and NSTextView avoids that, the total savings is ~60-80ms -- significant for the sub-100ms target, but at the cost of maintaining two full rendering paths indefinitely.

**Detection:** QA matrix: test every user action (scroll, select, copy, Cmd+F, print, export, monospace toggle) across both backends with the same document.

**Confidence:** MEDIUM (based on architectural analysis; severity depends on scope of NSTextView integration)

---

### Pitfall 8: UTF-8 Boundary Corruption When Splitting Input for cmark_parser_feed

**What goes wrong:** When feeding input to cmark in chunks (for memory efficiency on large files), splitting a Swift String at arbitrary character positions may split a multi-byte UTF-8 sequence. Feeding a partial UTF-8 sequence to cmark produces parsing errors, garbled text, or silently corrupted output.

**Why it happens:** Swift's `String` operates on extended grapheme clusters, not bytes. A "character" may be 1-4 UTF-8 bytes. Slicing at byte position N may land in the middle of a multi-byte character. cmark expects valid UTF-8 input and does not validate partial sequences gracefully.

**Prevention:**
- Split input only at ASCII-safe boundaries: newline characters (`\n`, always 1 byte in UTF-8) or blank lines.
- Use the `String.utf8` view for splitting and verify each chunk starts and ends at valid UTF-8 sequence boundaries.
- Simplest approach: split at `\n\n` (blank line) boundaries, which are guaranteed safe and align with markdown block boundaries.

**Detection:** Test with files containing multi-byte characters (CJK text, emoji, accented characters) near chunk boundaries.

**Confidence:** HIGH (UTF-8 encoding rules are deterministic)

---

## Minor Pitfalls

### Pitfall 9: String(cString:) Scans for Null Terminator -- Hidden O(n) Cost

**What goes wrong:** `String(cString: htmlCStr)` scans the entire C string to find the null terminator, then copies all bytes. For a 1MB HTML output, this is a redundant scan when the length could be known from cmark's allocator or computed once with `strlen`.

**Prevention:** If pursuing zero-copy, compute length once and use `String(bytes: UnsafeBufferPointer(start: htmlCStr, count: len), encoding: .utf8)`. However, measure first -- this is likely <1ms even for large documents and may not justify the unsafe code.

**Confidence:** HIGH (trivial to verify with Instruments)

---

### Pitfall 10: WKWebView Pool Memory Baseline May Exceed the Optimization's Savings

**What goes wrong:** Each pre-warmed WKWebView adds ~50-200MB to baseline RSS (WebContent process, networking process, JavaScript engine initialization). A pool of 3 views adds 150-600MB. The optimization saves ~40-80ms of init time per file. For a lightweight viewer app, the memory cost may exceed what the entire optimization milestone is trying to reduce.

**Prevention:**
- Limit pool to 1 view (current pre-warm approach already does this).
- Measure actual WKWebView init time on target hardware. If init is <20ms on M-series Macs, pooling beyond 1 may not be worth the memory cost.
- Implement lazy replenishment: after using the pre-warmed view, create the next one asynchronously rather than maintaining a constant pool size.
- Monitor system memory with `os_proc_available_memory()` and skip pre-warming if available memory is below a threshold.

**Confidence:** HIGH (WKWebView process architecture memory costs are well-documented)

---

### Pitfall 11: cmark Allocator Compatibility With Swift's free()

**What goes wrong:** When attempting zero-copy bridging with `Data(bytesNoCopy:count:deallocator:)`, the deallocator must call the same `free()` that cmark used for allocation. If cmark is configured with a custom allocator (via `cmark_render_html_with_mem`), calling `free()` on memory allocated by a custom allocator is undefined behavior.

**Prevention:** The current code passes `cmark_get_default_mem_allocator()` which uses standard `malloc`/`free`. Verify this if the vendored fork changes the allocator. If a custom allocator is used, the deallocator must call the custom allocator's free function, not `free()`.

**Confidence:** HIGH (C memory management semantics are deterministic)

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Severity | Mitigation |
|-------------|---------------|----------|------------|
| Vendor swift-cmark | Fork drift from upstream (Pitfall 5) | Moderate | Add new files only; do not modify existing cmark source |
| Vendor swift-cmark | Build system complexity integrating C source | Moderate | Use SPM local package with C target, not manual Xcode file references |
| WKWebView warm pool | Blank screens from dead processes (Pitfall 2) | **Critical** | Implement process termination handler + health checks |
| WKWebView warm pool | State leakage between reuses (Pitfall 6) | Moderate | prepareForReuse() with full reset before dequeue |
| WKWebView warm pool | Memory overhead exceeds savings (Pitfall 10) | Minor | Limit to pool of 1; measure init cost on target hardware |
| Streaming parse | cmark cannot emit partial AST (Pitfall 1) | **Critical** | Redesign: walk completed AST, render first N nodes for first paint |
| Streaming parse | UTF-8 boundary corruption (Pitfall 8) | Moderate | Split only at newline boundaries |
| Zero-copy bridge | Dangling pointers from premature free (Pitfall 3) | **Critical** | Transfer ownership via Data wrapper; run ASan in CI |
| Zero-copy bridge | Allocator mismatch (Pitfall 11) | Minor | Verify cmark uses default malloc allocator |
| Zero-copy bridge | Marginal gain vs. complexity (Pitfall 9) | Minor | Measure before implementing |
| NSTextView backend | Feature parity impossible (Pitfall 4) | **Critical** | Narrow scope to trivially simple docs; measure bottleneck first |
| NSTextView backend | Behavioral divergence (Pitfall 7) | Moderate | Fast-preview-only mode; fall back to WKWebView for advanced ops |

## Recommended Phase Ordering Based on Risk

1. **Vendor swift-cmark** first -- unlocks AST walking needed by streaming phase; pitfalls are manageable (fork maintenance) and well-understood.
2. **WKWebView warm pool** second -- extends existing pre-warm pattern; critical pitfall (blank screens) has known mitigation (process termination handler).
3. **Streaming parse (AST-walk approach)** third -- depends on vendored cmark for AST iteration; must be designed around the atomic-parse constraint (Pitfall 1).
4. **Zero-copy bridge** fourth -- incremental optimization; measure first to confirm it addresses an actual bottleneck before adding unsafe code.
5. **NSTextView backend** last or defer -- highest risk (4 pitfalls, 2 critical), lowest certainty of payoff, most code to maintain. Strongly recommend measuring the actual WKWebView bottleneck before committing to this.

---

## Sources

- [cmark GitHub repository and API](https://github.com/commonmark/cmark)
- [cmark man page -- streaming parser API](https://www.mankier.com/3/cmark)
- [cmark-gfm man page](https://man.archlinux.org/man/cmark-gfm.3.en)
- [WKWebView Memory Leaks -- Embrace.io](https://embrace.io/blog/wkwebview-memory-leaks/)
- [Handling Blank WKWebViews -- Never Meant](https://nevermeant.dev/handling-blank-wkwebviews/)
- [WKWebView crashes after repeated reloads -- Apple Developer Forums](https://developer.apple.com/forums/thread/767719)
- [WebKit Bug 176855 -- Unable to recover after process termination](https://bugs.webkit.org/show_bug.cgi?id=176855)
- [webViewWebContentProcessDidTerminate -- Apple Documentation](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:))
- [Unsafe Swift -- WWDC20](https://developer.apple.com/videos/play/wwdc2020/10648/)
- [Advanced Memory Management with Unsafe Swift](https://medium.com/@maxches/advanced-memory-management-with-unsafe-swift-f34d5bfbd78f)
- [UnsafeBufferPointer lifetime -- Swift Forums](https://forums.swift.org/t/can-an-unsafebufferpointer-to-local-scope-array-outlive-its-own-reference/47070)
- [The Peril of the Ampersand -- Apple Developer Forums](https://developer.apple.com/forums/thread/674633)
- [NSTextView -- Apple Documentation](https://developer.apple.com/documentation/appkit/nstextview)
- [SwiftUI on macOS: text views -- Eclectic Light Company](https://eclecticlight.co/2024/05/07/swiftui-on-macos-text-rich-text-markdown-html-and-pdf-views/)
- [Deep Dive into SwiftUI Rich Text Layout -- fatbobman](https://fatbobman.com/en/posts/a-deep-dive-into-swiftui-rich-text-layout/)
- [SPM Dependency Vendoring -- swiftlang/swift-package-manager#4507](https://github.com/swiftlang/swift-package-manager/issues/4507)
- [Integrating cmark-gfm and swift-cmark -- Swift Forums](https://forums.swift.org/t/integrating-cmark-gfm-and-swift-cmark/55557)
