# Phase 8: Streaming Pipeline - Research

**Researched:** 2026-04-16
**Domain:** Concurrent parse-render pipeline, buffer reuse, OSSignposter performance measurement
**Confidence:** HIGH

## Summary

Phase 8 transforms MDViewer's rendering pipeline from a sequential "parse all, then display" model to a concurrent streaming model where the first HTML chunk reaches WKWebView while the C renderer is still producing subsequent chunks. The current architecture already has all the necessary building blocks: the vendored cmark-gfm produces chunks via a C callback (Phase 6), WKWebView has a `loadHTMLString` + `appendChunk` progressive injection path, and the template is pre-split. The missing piece is concurrency coordination: the C callback currently collects all chunks into an array, then Swift wraps the first chunk in a template and hands everything to the main thread as a batch.

The core change is to replace the batch-collect-then-display pattern with a producer-consumer pipeline where the first chunk triggers WKWebView load immediately (from the background thread via main-thread dispatch), and subsequent chunks are queued for injection after first paint. Additionally, STRM-02 requires eliminating per-render String allocations in template concatenation by reusing a pre-allocated buffer.

**Primary recommendation:** Introduce a streaming render method that dispatches the first chunk to the main thread inside the C callback (on first invocation), while remaining chunks accumulate in the context object for later injection. Use a pre-sized `Data` or `UnsafeMutableBufferPointer<UInt8>` for template concatenation to satisfy STRM-02's buffer reuse requirement.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| STRM-01 | First HTML chunk delivered to WKWebView while remaining chunks still being rendered from AST | Streaming callback architecture: first chunk dispatches to main thread inside C callback; remaining chunks accumulate |
| STRM-02 | Template concatenation reuses buffers instead of creating new String allocations per render | Pre-allocated byte buffer for prefix+chunk+suffix assembly; avoid Swift String concatenation |
| PERF-01 | Warm launch to first visible content under 150ms for WKWebView path (OSSignposter) | New signpost intervals around streaming pipeline stages; existing OSSignposter infrastructure |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Streaming chunk production | C Library (cmark-gfm) | -- | Chunks are produced by the C callback; already emits at top-level block boundaries |
| First-chunk dispatch | Swift (MarkdownRenderer) | AppDelegate | Renderer's callback dispatches first chunk to main thread; AppDelegate coordinates display |
| Template concatenation | Swift (MarkdownRenderer) | -- | prefix + chunk + suffix assembly is a pure data operation |
| Buffer reuse | Swift (MarkdownRenderer) | -- | Pre-allocated buffer lives across renders in the renderer instance |
| WKWebView load | Swift (WebContentView) | -- | loadHTMLString for first chunk, appendChunk JS for subsequent |
| Performance measurement | Swift (OSSignposter) | -- | Existing signposter infrastructure; add streaming-specific intervals |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| cmark-gfm (vendored) | Custom (Phase 6) | Chunked HTML rendering with C callback | Already vendored; callback API is the streaming foundation |
| OSSignposter | macOS 13+ SDK | Performance interval measurement | Already used throughout; required for PERF-01 |
| WKWebView | macOS 13+ SDK | HTML rendering surface | Existing path; loadHTMLString + JS chunk injection |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| DispatchQueue | Foundation | Main-thread dispatch for first chunk | Coordinate background parse -> UI display |
| UnsafeMutableBufferPointer | Swift stdlib | Zero-alloc template concatenation buffer | STRM-02 buffer reuse |

No new dependencies are needed. This phase is purely architectural refactoring of existing components.

## Architecture Patterns

### System Architecture Diagram

**Current (sequential):**
```
Background Thread                          Main Thread
-----------------                          -----------
File read (mappedIfSafe)
  |
  v
cmark_parser_feed + finish
  |
  v
cmark_render_html_chunked
  -> callback collects ALL chunks
  |
  v
template.prefix + chunk[0] + template.suffix
  |
  v
RenderResult(page, remainingChunks)  --->  displayResult()
                                             |
                                             v
                                           loadHTMLString(page)
                                             |
                                           [first paint signal]
                                             |
                                           injectRemainingChunks()
```

**Proposed (streaming):**
```
Background Thread                          Main Thread
-----------------                          -----------
File read (mappedIfSafe)
  |
  v
cmark_parser_feed + finish
  |
  v
cmark_render_html_chunked
  -> callback chunk #1  ---- dispatch ---> displayResult(firstPage)
  |                                          |
  -> callback chunk #2                     loadHTMLString(page)
  |                                          |
  -> callback chunk #3                     [first paint signal]
  |                                          |
  -> callback chunk #N (final)             injectRemainingChunks()
  |                                          (chunks already queued)
  v
[parse complete -- all chunks delivered]
```

Key difference: The first chunk crosses the thread boundary while the C renderer is still iterating the AST and producing chunks 2..N. This overlaps parse time with WKWebView's HTML load time.

### Recommended Project Structure

No new files needed. Changes are to existing files:

```
MDViewer/
  MarkdownRenderer.swift   # New streaming render method + buffer reuse
  AppDelegate.swift        # Updated openFile() to use streaming render
  WebContentView.swift     # Minor: accept chunks incrementally (or keep current pattern)
```

### Pattern 1: Streaming Callback with First-Chunk Dispatch

**What:** Inside the C callback closure, detect the first chunk invocation and immediately dispatch it to the main thread for WKWebView loading. Subsequent chunks are appended to a shared context object that the main thread reads after first paint.

**When to use:** When the first chunk must reach WKWebView before parsing completes.

**Example:**
```swift
// Source: project-specific architecture [VERIFIED: codebase analysis]
func renderStreaming(
    fileURL: URL,
    template: SplitTemplate,
    onFirstChunk: @escaping (String, Bool) -> Void,
    onComplete: @escaping ([String]) -> Void
) {
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
          let markdown = String(data: data, encoding: .utf8) else {
        return
    }

    let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE
    guard let parser = cmark_parser_new(options) else { return }
    defer { cmark_parser_free(parser) }

    // Attach extensions...
    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    guard let root = cmark_parser_finish(parser) else { return }
    defer { cmark_node_free(root) }

    let ctx = StreamingRenderContext()
    let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
    defer { Unmanaged<StreamingRenderContext>.fromOpaque(ctxPtr).release() }

    // Capture closures in context for use inside C callback
    ctx.onFirstChunk = { [template] firstChunkHTML, hasMermaid in
        // Build page using reusable buffer (STRM-02)
        let page = Self.assembleTemplate(template, chunk: firstChunkHTML)
        DispatchQueue.main.async {
            onFirstChunk(page, hasMermaid)
        }
    }

    cmark_render_html_chunked(
        root, options, cachedExtList,
        cmark_get_default_mem_allocator(),
        chunkByteLimit,
        { (data, len, isLast, hasMermaid, userdata) -> Int32 in
            guard let data = data, let userdata = userdata else { return 1 }
            let ctx = Unmanaged<StreamingRenderContext>
                .fromOpaque(userdata).takeUnretainedValue()

            if len > 0 {
                let chunk = String(
                    decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(data)
                            .assumingMemoryBound(to: UInt8.self),
                        count: len),
                    as: UTF8.self)

                if !ctx.firstChunkSent {
                    ctx.firstChunkSent = true
                    if hasMermaid != 0 { ctx.hasMermaid = true }
                    ctx.onFirstChunk?(chunk, ctx.hasMermaid)
                } else {
                    ctx.remainingChunks.append(chunk)
                }
            }
            if hasMermaid != 0 { ctx.hasMermaid = true }
            return 0
        },
        ctxPtr
    )

    // After C rendering completes, deliver remaining chunks
    let remaining = ctx.remainingChunks
    DispatchQueue.main.async {
        onComplete(remaining)
    }
}
```

### Pattern 2: Buffer Reuse for Template Concatenation (STRM-02)

**What:** Instead of `template.prefix + firstChunk + template.suffix` (which creates 2 intermediate String allocations), pre-allocate a byte buffer sized to `prefix.utf8.count + chunkByteLimit + suffix.utf8.count` and reuse it across renders.

**When to use:** Every render pass.

**Example:**
```swift
// Source: Swift stdlib documentation [VERIFIED: Swift language reference]
final class MarkdownRenderer {
    // Pre-allocated buffer for template assembly (STRM-02)
    private var templateBuffer: [UInt8] = []
    private var prefixBytes: [UInt8] = []
    private var suffixBytes: [UInt8] = []

    func prepareTemplateBuffer(template: SplitTemplate) {
        prefixBytes = Array(template.prefix.utf8)
        suffixBytes = Array(template.suffix.utf8)
        // Reserve for prefix + max chunk + suffix
        let capacity = prefixBytes.count + chunkByteLimit + suffixBytes.count
        templateBuffer.reserveCapacity(capacity)
    }

    static func assembleTemplate(
        prefixBytes: [UInt8],
        suffixBytes: [UInt8],
        buffer: inout [UInt8],
        chunk: String
    ) -> String {
        buffer.removeAll(keepingCapacity: true)  // Reuse allocation
        buffer.append(contentsOf: prefixBytes)
        buffer.append(contentsOf: chunk.utf8)
        buffer.append(contentsOf: suffixBytes)
        return String(decoding: buffer, as: UTF8.self)
    }
}
```

The key insight is `removeAll(keepingCapacity: true)` -- this zeros the count but retains the allocated memory, so subsequent renders reuse the same heap allocation. [VERIFIED: Swift Array documentation]

### Pattern 3: Signpost Intervals for Streaming Pipeline (PERF-01)

**What:** Add granular OSSignposter intervals to measure the streaming pipeline's actual first-chunk latency.

**Example:**
```swift
// Source: existing codebase pattern [VERIFIED: AppDelegate.swift, MarkdownRenderer.swift]
let streamState = renderingSignposter.beginInterval("stream-first-chunk", id: spID)
// ... first chunk dispatched ...
renderingSignposter.endInterval("stream-first-chunk", streamState)
```

Intervals to measure:
1. `file-read` -- already exists
2. `parse-feed` -- cmark_parser_feed + finish (new, split from existing parse+chunk)
3. `stream-first-chunk` -- time from render start to first chunk dispatch
4. `template-assemble` -- buffer concatenation time
5. `stream-remaining` -- time for all remaining chunks to complete
6. `open-to-paint` -- already exists (end-to-end)

### Anti-Patterns to Avoid

- **Dispatching every chunk individually to main thread:** The first chunk dispatch is valuable (overlaps with WKWebView load). But subsequent chunks should be batched and injected after first paint, not dispatched one-by-one during rendering -- the main thread dispatch overhead would negate the streaming benefit.

- **Using DispatchSemaphore or locks between background and main thread:** The streaming model must be fire-and-forget for the first chunk. The background thread must not block waiting for the main thread to acknowledge receipt. Use async dispatch, not synchronous coordination.

- **Creating a new buffer per render:** The entire point of STRM-02 is that the buffer persists across renders. Do not allocate inside the render method.

- **Capturing `self` strongly in C callback closures:** The existing pattern uses `Unmanaged` with explicit retain/release. Continue this pattern for the streaming context.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Thread-safe chunk queue | Lock-based producer-consumer queue | Simple append + DispatchQueue.main.async | Only one consumer (main thread), fire-and-forget dispatch is sufficient |
| Performance profiling framework | Custom timing code | OSSignposter | Already integrated, works with Instruments, zero overhead when not recording |
| Template engine | String interpolation or regex replacement | Pre-split template + byte buffer concatenation | SplitTemplate already handles this; just switch from String concat to buffer |

**Key insight:** The streaming pipeline does not need complex concurrency primitives. The C callback runs synchronously on the background thread. The "streaming" aspect is simply dispatching the first chunk to the main thread mid-callback, then continuing the loop.

## Common Pitfalls

### Pitfall 1: Mermaid Flag Race Condition
**What goes wrong:** The `hasMermaid` flag might be set by a later chunk (chunk 3 has a mermaid block), but the first chunk was already dispatched to the main thread without mermaid awareness.
**Why it happens:** In the current batch model, hasMermaid is known after all chunks are processed. In streaming, the first chunk dispatches before later chunks are seen.
**How to avoid:** The first chunk only needs hasMermaid for its own content. The mermaid loading happens after first paint anyway (in `injectRemainingChunks`). Pass hasMermaid with the completion callback (after all chunks), not with the first chunk. Or: detect mermaid in the first chunk only and defer full mermaid detection to completion.
**Warning signs:** Mermaid blocks in files where the first mermaid block appears after 64KB of content render as raw text.

### Pitfall 2: First Chunk Too Small
**What goes wrong:** If the file is very short (under 64KB), there's only one chunk. The streaming path fires `onFirstChunk` and `onComplete` with an empty remaining array. No performance gain, but must not regress.
**Why it happens:** The C callback emits chunks at block boundaries when buffer exceeds 64KB. Small files produce exactly one chunk with `isLast=1`.
**How to avoid:** Handle the single-chunk case as a fast path. The streaming method should degrade gracefully to the current behavior when there's only one chunk.
**Warning signs:** Single-chunk files show different timing characteristics or visual glitches.

### Pitfall 3: WebContentView Receives Chunks Before loadHTMLString Completes
**What goes wrong:** If remaining chunks are dispatched to the main thread before `loadHTMLString` has finished, `appendChunk` JS calls fail silently.
**Why it happens:** `loadHTMLString` is asynchronous. The `firstPaint` message handler gates chunk injection, but the streaming path might try to inject before that signal.
**How to avoid:** The current `injectRemainingChunks()` pattern already waits for the `firstPaint` JS message. Ensure the streaming path stores remaining chunks on `WebContentView` and lets the existing first-paint handler trigger injection. Do not inject remaining chunks before first paint.
**Warning signs:** Missing content after the first screenful.

### Pitfall 4: Buffer Reuse Across Concurrent Renders
**What goes wrong:** If two files are opened simultaneously, both background renders try to use the same template buffer, causing data corruption.
**Why it happens:** `MarkdownRenderer` is shared (single instance in AppDelegate). If two `openFile` calls overlap on the background queue, the buffer is shared state.
**How to avoid:** Either (a) make the buffer local to the render call (sacrificing reuse for safety), or (b) use a per-call buffer with the renderer holding a reusable buffer that's checked out/returned. Given that concurrent opens are rare and the buffer is tiny (~200KB), option (a) with `removeAll(keepingCapacity: true)` on a context-local buffer is safest. Alternatively, use a serial DispatchQueue for rendering.
**Warning signs:** Garbled HTML in windows when multiple files are opened simultaneously via drag-and-drop.

### Pitfall 5: Template Assembly Dominates Streaming Benefit
**What goes wrong:** The time saved by streaming (overlapping parse with WKWebView load) is smaller than expected because template assembly itself is fast (~0.1ms).
**Why it happens:** The real bottleneck is WKWebView's `loadHTMLString` processing time, not template concatenation.
**How to avoid:** Measure before and after with Instruments. The streaming benefit is most visible on large files (100KB+ markdown) where cmark takes 5-15ms and WKWebView load takes 30-50ms. For small files, the improvement may be imperceptible.
**Warning signs:** Warm launch times don't improve measurably for small files.

## Code Examples

### Current openFile Flow (to be modified)
```swift
// Source: AppDelegate.swift [VERIFIED: codebase]
private func openFile(_ url: URL) {
    guard let tmpl = template else { return }
    let paintState = appSignposter.beginInterval("open-to-paint")
    pendingFileOpens += 1

    let renderer = self.renderer
    DispatchQueue.global(qos: .userInitiated).async {
        guard let result = renderer.renderFullPage(fileURL: url, template: tmpl) else {
            // error handling...
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingFileOpens -= 1
            self?.displayResult(result, for: url, paintState: paintState)
        }
    }
}
```

### Proposed Streaming openFile Flow
```swift
// Source: proposed architecture [ASSUMED]
private func openFile(_ url: URL) {
    guard let tmpl = template else { return }
    let paintState = appSignposter.beginInterval("open-to-paint")
    pendingFileOpens += 1

    let renderer = self.renderer
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        // Read file
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let markdown = String(data: data, encoding: .utf8) else {
            DispatchQueue.main.async {
                self?.pendingFileOpens -= 1
                // error alert...
            }
            return
        }

        var firstChunkDispatched = false
        var contentView: WebContentView?

        renderer.renderStreaming(markdown: markdown, template: tmpl,
            onFirstChunk: { page, hasMermaid in
                // Called from background thread -- dispatch to main
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let cv = self.webViewPool.dequeue() ?? WebContentView(frame: .zero)
                    cv.delegate = self
                    contentView = cv
                    // Create window and start loading first chunk
                    self.displayStreamingFirst(cv, page: page, url: url,
                                              paintState: paintState)
                }
                firstChunkDispatched = true
            },
            onComplete: { remainingChunks, hasMermaid in
                DispatchQueue.main.async { [weak self] in
                    self?.pendingFileOpens -= 1
                    // Store remaining chunks on the content view
                    // They'll be injected after firstPaint signal
                    contentView?.setRemainingChunks(remainingChunks,
                                                    hasMermaid: hasMermaid)
                }
            }
        )
    }
}
```

### Buffer Reuse Assembly
```swift
// Source: Swift stdlib [VERIFIED: Array.removeAll(keepingCapacity:)]
private var assemblyBuffer: [UInt8] = []

func assembleFirstPage(template: SplitTemplate, chunk: String) -> String {
    assemblyBuffer.removeAll(keepingCapacity: true)
    assemblyBuffer.append(contentsOf: template.prefix.utf8)
    assemblyBuffer.append(contentsOf: chunk.utf8)
    assemblyBuffer.append(contentsOf: template.suffix.utf8)
    return String(decoding: assemblyBuffer, as: UTF8.self)
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Regex-based HTML chunking | C callback chunking at AST block boundaries | Phase 6 (v2.1) | Foundation for streaming |
| Single pre-warmed WKWebView | WebViewPool with 2 views | Phase 7 (v2.1) | Pool dequeue is near-instant |
| String(contentsOf:) for file read | Data(contentsOf:options:.mappedIfSafe) | v2.0 Phase 2 | Memory-mapped read avoids heap copy |
| evaluateJavaScript for chunks | callAsyncJavaScript with typed arguments | v2.0 Phase 2 | Eliminates injection risk |

**Relevant out-of-scope decisions:**
- Incremental cmark parsing is NOT viable: `cmark_parser_finish()` is required before AST access. Streaming must be post-parse (during HTML rendering from the AST). [VERIFIED: REQUIREMENTS.md Out of Scope]
- Zero-copy C-to-JS bridge deferred: <0.1ms cost measured. [VERIFIED: STATE.md decisions]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `removeAll(keepingCapacity: true)` on `[UInt8]` retains the heap allocation | Buffer Reuse pattern | Would need alternative buffer strategy (e.g., UnsafeMutableBufferPointer) |
| A2 | WKWebView `loadHTMLString` takes 30-50ms, making streaming overlap worthwhile for large files | Pitfall 5 | If loadHTMLString is faster, streaming benefit is negligible (but no regression) |
| A3 | Concurrent renders of the same MarkdownRenderer are possible when multiple files are opened simultaneously | Pitfall 4 | If AppDelegate serializes opens, buffer can safely live on the renderer |

## Open Questions (RESOLVED)

1. **Thread safety of shared buffer** RESOLVED: Per-call local buffer with removeAll(keepingCapacity: true); no locks per research recommendation.
   - What we know: AppDelegate dispatches to `.global(qos: .userInitiated)` which is a concurrent queue. Multiple drag-and-drop files could trigger concurrent renders.
   - What's unclear: Whether to make the buffer per-render-call or serialize renders.
   - Recommendation: Use a per-call buffer with `removeAll(keepingCapacity: true)` semantics via a local array. The allocation cost is trivial for a ~200KB buffer on a background thread. Buffer reuse across calls on the same thread can be achieved by making MarkdownRenderer use a serial queue internally.

2. **WebContentView API for deferred chunk delivery** RESOLVED: Add setRemainingChunks(_:hasMermaid:) method with firstPaint interlock.
   - What we know: Current `loadContent(page:remainingChunks:hasMermaid:)` expects all data at once.
   - What's unclear: Whether to split into two methods or add a `setRemainingChunks` method.
   - Recommendation: Add a `setRemainingChunks(_:hasMermaid:)` method. If chunks arrive before first paint, they're stored. If first paint already fired, inject immediately.

3. **Warm launch measurement methodology for 150ms target** RESOLVED: OSSignposter intervals measure streaming pipeline stages; profile before/after with Instruments.
   - What we know: Current warm launch is 184.50ms on M4 Max. OSSignposter is already instrumented.
   - What's unclear: Exact contribution of the streaming overlap to latency reduction.
   - Recommendation: Profile with Instruments before and after. The 34ms gap (184 -> 150) should be achievable by overlapping parse (~10ms) with WKWebView load (~30-50ms), especially combined with the pool from Phase 7.

## Environment Availability

Step 2.6: SKIPPED (no external dependencies -- all changes are to existing Swift source files using macOS SDK APIs already in use).

## Security Domain

No new attack surface introduced. All changes are internal pipeline refactoring:
- No new IPC channels
- No new file I/O patterns (same mappedIfSafe read)
- No new JS evaluation (same appendChunk pattern)
- Buffer reuse does not expose memory across documents (removeAll clears content)

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `MarkdownRenderer.swift`, `AppDelegate.swift`, `WebContentView.swift`, `WebViewPool.swift`
- Codebase analysis: `Vendor/cmark-gfm/src/html.c` -- chunked rendering callback API
- Codebase analysis: `Vendor/cmark-gfm/src/include/cmark-gfm.h` -- C function signature

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` -- requirement definitions and out-of-scope decisions
- `.planning/STATE.md` -- accumulated project decisions
- `.planning/research/ARCHITECTURE.md` -- current architecture snapshot

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies; all APIs are already used in the codebase
- Architecture: HIGH -- the streaming pattern is a straightforward refactoring of existing batch-collect pattern
- Pitfalls: HIGH -- identified through direct analysis of the C callback API and Swift concurrency model

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (stable -- no external dependencies to go stale)
