# Phase 2: Large File Memory & Progressive Rendering - Research

**Researched:** 2026-04-06
**Domain:** Memory-mapped file I/O, WKWebView typed JS bridge, byte-aware HTML chunking
**Confidence:** HIGH

## Summary

Phase 2 addresses three tightly related problems in the existing rendering pipeline: (1) heap-allocating the entire file contents on read, (2) splitting HTML into only 2 chunks regardless of document size, and (3) using unsafe string-interpolated JavaScript for chunk injection. All three changes target existing code paths in `MarkdownRenderer.swift` and `WebContentView.swift` with well-understood Apple APIs.

The memory-mapped read uses `Data(contentsOf:options:.mappedIfSafe)` followed by `String(data:encoding:)`. While the `String` initializer will copy the data to heap (Swift strings own their storage), the key benefit is that the full file is never loaded into a contiguous `Data` heap allocation -- the kernel pages in only the portions accessed during UTF-8 decoding. For a 10MB file, peak heap should be dominated by the resulting `String` plus the cmark parser output, not by a separate `Data` buffer AND a `String`.

The chunk injection migration from `evaluateJavaScript` to `callAsyncJavaScript` is straightforward. The API is available since macOS 11 (deployment target is macOS 13). It accepts a `[String: Any]` arguments dictionary where strings are automatically converted to JS strings -- no manual escaping needed. Each chunk is injected individually with 16ms staggering via separate `callAsyncJavaScript` calls.

**Primary recommendation:** Implement byte-size-based N-chunk splitting first (it changes the data structure), then wire up `callAsyncJavaScript` for injection, then swap file reading to `mappedIfSafe` last (smallest, most isolated change).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Use `Data(contentsOf:options:.mappedIfSafe)` then decode to `String` -- avoids loading the entire file into heap memory. This directly satisfies MEM-02.
- **D-02:** Keep the existing `renderFullPage(fileURL:template:)` signature -- the change is internal to the file read step only.
- **D-03:** Split HTML at block-tag boundaries (p, h1-h6, div, pre, blockquote, table, ul, ol, hr, li) with a target of <=64KB per chunk. This replaces the current 2-chunk approach with true N-chunk rendering (RENDER-01).
- **D-04:** The current `chunkThreshold = 50` (block tags) approach should be replaced with byte-size-based splitting. Walk block-tag positions and accumulate until the 64KB threshold is reached, then split.
- **D-05:** Replace `evaluateJavaScript` with `callAsyncJavaScript` using a typed `html` argument for each chunk. This eliminates the string interpolation injection risk (RENDER-02) and removes the need for the manual character escaping loop.
- **D-06:** Inject chunks one at a time with 16ms staggering (preserve current timing), not all at once in a single JS call.
- **D-07:** Chunks appear seamlessly -- no loading spinners or visual indicators between chunks. Content simply grows as chunks are appended (matches current behavior).
- **D-08:** First screen of content appears before remaining chunks finish loading (existing behavior preserved via firstPaint callback).

### Claude's Discretion
- Whether to keep `chunkHTML()` as a method on `MarkdownRenderer` or extract it -- Claude can decide based on code organization.
- The exact staggering timing (16ms vs other values) for chunk injection -- preserve 16ms unless profiling shows a different value is better.
- Whether `renderFullPage(markdown:template:)` (the non-file overload used by tests) also gets N-chunk splitting or stays as-is.

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MEM-02 | File reading uses `Data(contentsOf:options:.mappedIfSafe)` -- 10MB+ files don't spike heap | Memory-mapped read pattern (see Architecture Patterns, Pattern 1); verified API availability macOS 10.4+ |
| RENDER-01 | True N-chunk progressive rendering -- HTML split at block boundaries into chunks <=64KB | Byte-size block-tag walker algorithm (see Architecture Patterns, Pattern 2); replaces current 2-chunk `chunkHTML` |
| RENDER-02 | Chunk injection uses `callAsyncJavaScript` with typed arguments instead of string interpolation | `callAsyncJavaScript` API (see Architecture Patterns, Pattern 3); available macOS 11+, deployment target is macOS 13 |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: macOS 13+ (Ventura minimum). All APIs must be available at this target.
- **No network**: All resources bundled. No new dependencies.
- **Read-only**: No file modification, no state persistence.
- **Speed**: First content visible in <200ms.
- **Concurrency**: `[weak self]` in all closures. Main thread for UI mutations. Background rendering on `DispatchQueue.global(qos: .userInitiated)`.
- **Access control**: `private` for implementation details. `final` on concrete classes.
- **Error handling**: `guard let` early returns. `defer` for C resource cleanup.
- **No async/await**: Explicitly out of scope per REQUIREMENTS.md.
- **OSSignposter**: Already instruments file-read, parse, chunk-split, chunk-inject stages -- new implementation must preserve these intervals.

## Standard Stack

### Core

| API | Availability | Purpose | Why Standard |
|-----|-------------|---------|--------------|
| `Data(contentsOf:options:.mappedIfSafe)` | macOS 10.4+ | Memory-mapped file reading | Foundation API. Kernel pages in data on demand instead of reading entire file to heap. |
| `String(data:encoding:.utf8)` | macOS 10.0+ | Decode mapped Data to String | Standard UTF-8 decoding. Copies to String storage but avoids double-allocation (Data + String). |
| `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:)` | macOS 11.0+ | Typed JS argument passing | Replaces string interpolation. Arguments dict `[String: Any]` auto-converts Swift String to JS string. No manual escaping. |
| `WKContentWorld.page` | macOS 11.0+ | Execute JS in page context | Required parameter for `callAsyncJavaScript`. `.page` runs in same context as page scripts (where `appendChunk` lives). |

### Supporting

| API | Availability | Purpose | When to Use |
|-----|-------------|---------|-------------|
| `NSRegularExpression` | macOS 10.7+ | Block-tag position finding | Already in use (`blockTagRegex`). Reused for byte-position-based splitting. |
| `NSString.substring(with:)` | macOS 10.0+ | Extract chunks by NSRange | Already in use. Efficient for range-based extraction from large strings. |
| `OSSignposter` | macOS 12+ | Pipeline instrumentation | Already in place from Phase 1. Preserve all interval markers. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `mappedIfSafe` | `alwaysMapped` | `alwaysMapped` works on all volumes including network/removable; `mappedIfSafe` falls back to normal read on unsafe volumes. Use `mappedIfSafe` -- it's the safer default for a desktop app that reads local files. |
| `callAsyncJavaScript` per chunk | Single `callAsyncJavaScript` with JSON array | Single call would require JS-side iteration and `setTimeout` scheduling. Per-chunk calls with Swift-side `DispatchQueue.main.asyncAfter` give more control and keep JS simple. |
| `String(data:encoding:)` | `String(decoding:as: UTF8.self)` | `String(decoding:as:)` is non-failable but replaces invalid bytes with replacement character. `String(data:encoding:)` returns nil on failure, matching existing error handling (guard-return-nil pattern). Use the failable version. |

## Architecture Patterns

### Recommended File Changes

```
MDViewer/
  MarkdownRenderer.swift     # mappedIfSafe file read, byte-size N-chunk splitting
  WebContentView.swift        # callAsyncJavaScript injection, per-chunk staggered dispatch
MDViewerTests/
  MarkdownRendererTests.swift # Updated chunk tests for N-chunk behavior
```

No new files needed. All changes modify existing code.

### Pattern 1: Memory-Mapped File Read (MEM-02)

**What:** Replace `try? String(contentsOf: fileURL, encoding: .utf8)` with a two-step read: `Data(contentsOf:options:.mappedIfSafe)` then `String(data:encoding:.utf8)`.

**When to use:** In `renderFullPage(fileURL:template:)` only. The `renderFullPage(markdown:template:)` overload already receives a String.

**Example:**
```swift
// BEFORE (current):
guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
    return nil
}

// AFTER (memory-mapped):
guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
      let markdown = String(data: data, encoding: .utf8) else {
    renderingSignposter.endInterval("file-read", readState)
    return nil
}
```

**Why this works:** `mappedIfSafe` tells the kernel to map the file into virtual address space rather than copying it to a heap buffer. When `String(data:encoding:)` reads the bytes for UTF-8 decoding, the kernel pages in only the needed portions. The resulting `String` owns its own heap storage, but we avoid the intermediate full-file `Data` heap allocation that `String(contentsOf:)` performs internally.

**Caveat:** `String(data:encoding:.utf8)` will still allocate heap for the String itself. The benefit is avoiding a SECOND full-file allocation (the `Data` buffer). For a 10MB file, peak heap goes from ~20MB (Data + String) to ~10MB (String only, with Data mapped not allocated).

### Pattern 2: Byte-Size N-Chunk Splitting (RENDER-01)

**What:** Replace the current `chunkThreshold = 50` block-tag-count approach with a byte-size-based splitter that produces N chunks of <=64KB each.

**When to use:** In `chunkHTML()` (or a replacement method).

**Algorithm:**
1. Find all block-tag positions using the existing `blockTagRegex`
2. Walk positions, accumulating byte size (using `NSRange.location` differences)
3. When accumulated size exceeds 64KB, split at the previous block-tag boundary
4. Continue until all content is chunked
5. If total HTML is <=64KB, return as a single chunk (no splitting needed)

**Example:**
```swift
private let chunkByteLimit = 64 * 1024  // 64KB

private func chunkHTML(_ html: String) -> [String] {
    let nsString = html as NSString
    let length = nsString.length
    
    // Small content: no splitting needed
    if nsString.lengthOfBytes(using: String.Encoding.utf8.rawValue) <= chunkByteLimit {
        return [html]
    }
    
    let matches = Self.blockTagRegex.matches(
        in: html,
        range: NSRange(location: 0, length: length)
    )
    
    guard !matches.isEmpty else { return [html] }
    
    var chunks: [String] = []
    var chunkStart = 0
    var lastSplitCandidate = 0
    
    for match in matches {
        let pos = match.range.location
        let candidateChunk = nsString.substring(
            with: NSRange(location: chunkStart, length: pos - chunkStart)
        )
        
        if candidateChunk.utf8.count > chunkByteLimit && lastSplitCandidate > chunkStart {
            // Split at previous block tag
            let chunk = nsString.substring(
                with: NSRange(location: chunkStart, length: lastSplitCandidate - chunkStart)
            )
            chunks.append(chunk)
            chunkStart = lastSplitCandidate
        }
        lastSplitCandidate = pos
    }
    
    // Remaining content
    if chunkStart < length {
        chunks.append(nsString.substring(from: chunkStart))
    }
    
    return chunks.isEmpty ? [html] : chunks
}
```

**Key design notes:**
- The 64KB limit is per-chunk, measured in UTF-8 bytes (not UTF-16 length)
- Splitting always happens at a block-tag boundary -- never mid-element
- A document with no block tags returns as a single chunk (safe fallback)
- The first chunk becomes `page` (embedded in template), remaining chunks are injected progressively

### Pattern 3: Typed Chunk Injection via callAsyncJavaScript (RENDER-02)

**What:** Replace the manual string-escaping `evaluateJavaScript` call with per-chunk `callAsyncJavaScript` calls using typed `html` argument.

**When to use:** In `injectRemainingChunks()` in `WebContentView.swift`.

**Example:**
```swift
private func injectRemainingChunks() {
    guard !remainingChunks.isEmpty else { return }
    
    let chunkInjectState = renderingSignposter.beginInterval("chunk-inject")
    let chunks = remainingChunks
    remainingChunks = []
    
    for (index, chunk) in chunks.enumerated() {
        let delay = Double(index) * 0.016  // 16ms stagger
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.webView.callAsyncJavaScript(
                "window.appendChunk(html)",
                arguments: ["html": chunk],
                in: nil,
                contentWorld: .page
            ) { _ in
                // Last chunk: end signpost
                if index == chunks.count - 1 {
                    renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                }
            }
        }
    }
}
```

**Key design notes:**
- `arguments: ["html": chunk]` -- the `chunk` String is passed as a typed argument, not interpolated into JS source
- `contentWorld: .page` -- executes in the page's JS context where `window.appendChunk` is defined
- `in: nil` -- uses the main frame (no iframes in this app)
- The completion handler is used to end the signpost interval after the last chunk
- `[weak self]` in the closure prevents retain cycles during staggered dispatch
- The existing `window.appendChunk(html)` JS function in `template.html` already accepts a single `html` parameter -- no JS changes needed

**callAsyncJavaScript argument types (verified):**
- Swift `String` maps to JS `string`
- Swift `NSNumber` / numeric types map to JS `number`
- Swift `NSNull` maps to JS `null`
- Swift `[String: Any]` maps to JS `object`
- Swift `[Any]` maps to JS `array`

### Anti-Patterns to Avoid

- **Building a JS array string and calling evaluateJavaScript:** This is the current approach and exactly what RENDER-02 eliminates. Never manually escape HTML content for JS template literals.
- **Using `alwaysMapped` instead of `mappedIfSafe`:** `alwaysMapped` can fail on network volumes. `mappedIfSafe` gracefully falls back to normal read.
- **Splitting on UTF-16 character count instead of UTF-8 byte count:** The 64KB limit is about data transfer size. Use `.utf8.count` for the measurement.
- **Calling `callAsyncJavaScript` in a tight loop without staggering:** Would flood the JS engine and block rendering. The 16ms stagger allows the browser to paint between chunks.
- **Moving signpost interval end into the async callback without capturing state:** The `chunkInjectState` must be captured by value (it's a struct), not by reference.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JS string escaping | Character-by-character escape loop | `callAsyncJavaScript` with typed arguments | The current 8-line escaping loop handles `\`, backtick, `$` but misses null bytes and surrogates. The typed API handles ALL edge cases automatically. |
| Memory-mapped reading | Custom `mmap`/`munmap` wrapper | `Data(contentsOf:options:.mappedIfSafe)` | Foundation handles page alignment, cleanup, and fallback. Raw `mmap` requires manual `munmap` and error handling. |
| Chunk scheduling | Custom `NSTimer` or `RunLoop` scheduling | `DispatchQueue.main.asyncAfter` | Simple, one-shot scheduling. Timer adds lifecycle management complexity for no benefit. |

**Key insight:** The current `injectRemainingChunks` method is 30 lines of manual string construction and escaping. The replacement with `callAsyncJavaScript` is ~15 lines with zero escaping logic.

## Common Pitfalls

### Pitfall 1: String(data:encoding:) Returns Nil for Invalid UTF-8

**What goes wrong:** `String(data:encoding:.utf8)` returns `nil` if the file contains invalid UTF-8 sequences. The `guard` returns nil and shows an error alert.
**Why it happens:** Some markdown files are saved in Latin-1 or other encodings. The current `String(contentsOf:encoding:.utf8)` has the same behavior, so this is not a regression.
**How to avoid:** Accept this as existing behavior. If encoding support is needed later, it's a separate enhancement.
**Warning signs:** User reports "Cannot Open File" for files that opened previously. Check encoding.

### Pitfall 2: callAsyncJavaScript Completion Handler Timing

**What goes wrong:** The signpost interval for chunk-inject ends when the last `callAsyncJavaScript` completion fires, but the JS hasn't actually appended the DOM nodes yet -- it's just been queued.
**Why it happens:** `callAsyncJavaScript` completion fires when the JS function returns, not when the DOM has been painted.
**How to avoid:** Accept this as a reasonable approximation. The signpost measures "time to schedule all chunk injections," not "time to paint all chunks." For more precise measurement, a JS-side `requestAnimationFrame` callback after the last append would be needed -- but that's over-engineering for this phase.
**Warning signs:** Signpost shows chunk-inject completing before visual rendering is done. This is expected.

### Pitfall 3: chunkByteLimit Threshold Too Small Creates Too Many Chunks

**What goes wrong:** If `chunkByteLimit` is set too low (e.g., 8KB), a 10MB file produces 150+ chunks. Each chunk requires a separate `callAsyncJavaScript` call with 16ms stagger, meaning total injection takes 2.4+ seconds.
**Why it happens:** Linear relationship: `total_time = chunk_count * 16ms`.
**How to avoid:** 64KB chunks (as decided in D-03) yield ~156 chunks for a 10MB file, totaling ~2.5 seconds. This is acceptable for a 10MB file where progressive rendering is the goal. For reference: 128KB chunks would halve injection time but double the time-to-render for each individual chunk.
**Warning signs:** Very large files take noticeably long to finish rendering. The 64KB value is a reasonable starting point; profiling in Phase 3 can tune it.

### Pitfall 4: NSString Length vs UTF-8 Byte Count Mismatch

**What goes wrong:** `NSString.length` returns UTF-16 code unit count, not UTF-8 byte count. Using `NSRange.location` differences to estimate byte size under-counts for ASCII (1:1) but could over-count for emoji/CJK.
**Why it happens:** NSString is internally UTF-16. The block-tag regex operates on `NSString` ranges.
**How to avoid:** Use `nsString.substring(with:range).utf8.count` for accurate byte measurement at each candidate split point. The performance cost of this check is negligible compared to the regex matching.
**Warning signs:** Chunks are inconsistently sized. Some chunks are much larger than 64KB.

### Pitfall 5: Signpost Interval Ends Before All Async Chunks Complete

**What goes wrong:** The current code ends the `chunk-inject` signpost immediately after calling `evaluateJavaScript` (line 142 in `WebContentView.swift`). With per-chunk async dispatch, ending the interval at the call site would measure only the loop setup time, not actual injection.
**Why it happens:** The staggered dispatch is asynchronous. The synchronous code after the loop returns immediately.
**How to avoid:** End the signpost in the completion handler of the LAST chunk's `callAsyncJavaScript` call (as shown in Pattern 3 example).
**Warning signs:** The chunk-inject signpost interval shows near-zero duration in Instruments.

## Code Examples

### Complete Memory-Mapped File Read

```swift
// In MarkdownRenderer.renderFullPage(fileURL:template:)
// Replace lines 67-72 of current implementation

let readState = renderingSignposter.beginInterval("file-read", id: spID)
guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
      let markdown = String(data: data, encoding: .utf8) else {
    renderingSignposter.endInterval("file-read", readState)
    return nil
}
renderingSignposter.endInterval("file-read", readState)
```

### Complete N-Chunk Splitter

```swift
// Replace chunkHTML(_:) and chunkThreshold in MarkdownRenderer

private let chunkByteLimit = 64 * 1024

private func chunkHTML(_ html: String) -> [String] {
    let nsString = html as NSString
    let length = nsString.length

    let matches = Self.blockTagRegex.matches(
        in: html,
        range: NSRange(location: 0, length: length)
    )

    // No block tags or small content: single chunk
    guard !matches.isEmpty else { return [html] }

    // Check if entire content fits in one chunk
    if html.utf8.count <= chunkByteLimit {
        return [html]
    }

    var chunks: [String] = []
    var chunkStart = 0

    for i in 1..<matches.count {
        let pos = matches[i].range.location
        let candidateRange = NSRange(location: chunkStart, length: pos - chunkStart)
        let candidate = nsString.substring(with: candidateRange)

        if candidate.utf8.count > chunkByteLimit {
            // Current accumulation exceeds limit.
            // Split at the previous block tag (matches[i-1]).
            let prevPos = matches[i - 1].range.location
            if prevPos > chunkStart {
                let chunkRange = NSRange(location: chunkStart, length: prevPos - chunkStart)
                chunks.append(nsString.substring(with: chunkRange))
                chunkStart = prevPos
            }
        }
    }

    // Append remaining
    if chunkStart < length {
        chunks.append(nsString.substring(from: chunkStart))
    }

    return chunks.isEmpty ? [html] : chunks
}
```

### Complete callAsyncJavaScript Injection

```swift
// Replace injectRemainingChunks() in WebContentView

private func injectRemainingChunks() {
    guard !remainingChunks.isEmpty else { return }

    let chunkInjectState = renderingSignposter.beginInterval("chunk-inject")
    let chunks = remainingChunks
    let chunkCount = chunks.count
    remainingChunks = []

    for (index, chunk) in chunks.enumerated() {
        let delay = Double(index) * 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.webView.callAsyncJavaScript(
                "window.appendChunk(html)",
                arguments: ["html": chunk],
                in: nil,
                contentWorld: .page
            ) { _ in
                if index == chunkCount - 1 {
                    renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                }
            }
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `evaluateJavaScript` with string interpolation | `callAsyncJavaScript` with typed arguments | macOS 11 / WWDC 2020 | Eliminates injection risk, removes manual escaping |
| `String(contentsOf:)` for large files | `Data(contentsOf:options:.mappedIfSafe)` + `String(data:encoding:)` | Always available | Avoids double heap allocation for file content |
| Fixed block-count chunking | Byte-size-based N-chunk splitting | N/A (project-specific) | Enables true progressive rendering for arbitrarily large files |

**Deprecated/outdated:**
- `evaluateJavaScript` for data passing: Still works but Apple's CodeQL rules flag it as a security smell. `callAsyncJavaScript` is the recommended replacement.

## Open Questions

1. **Should `renderFullPage(markdown:template:)` (test overload) also get N-chunk splitting?**
   - What we know: This overload is used by `MarkdownRendererTests` and calls `render(markdown:)` which calls `chunkHTML()`. If `chunkHTML` changes, this overload automatically gets N-chunk behavior.
   - What's unclear: Whether test expectations need updating (current test expects `chunks.count > 1` for 100 headings).
   - Recommendation: Let it inherit the new behavior. Update the test to verify N-chunk output (e.g., verify chunk count matches expected byte-size splitting, not just > 1).

2. **Should `chunkHTML` stay on `MarkdownRenderer` or be extracted?**
   - What we know: `MarkdownRenderer` is stateless and `final`. The chunk logic is tightly coupled to HTML output.
   - What's unclear: Whether the byte-size logic makes the method complex enough to warrant extraction.
   - Recommendation: Keep it on `MarkdownRenderer`. The method is still a pure function (HTML string in, string array out). Extracting adds indirection with no testability benefit since it's already tested via `render()`.

## Sources

### Primary (HIGH confidence)
- [NSData.ReadingOptions | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/nsdata/readingoptions) - `mappedIfSafe` semantics
- [callAsyncJavaScript | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:in:completionhandler:)) - API signature and availability (macOS 11+)
- [CodeQL: JavaScript Injection](https://codeql.github.com/codeql-query-help/swift/swift-unsafe-js-eval/) - Safe pattern using `callAsyncJavaScript` with typed arguments, verified code examples
- [Mapping Files Into Memory | Apple Developer](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html) - Memory mapping fundamentals

### Secondary (MEDIUM confidence)
- [iOS 14: What is new for WKWebView](https://nemecek.be/blog/32/ios-14-what-is-new-for-wkwebview) - `callAsyncJavaScript` overview and argument type mapping
- [Swift Forums: Memory-map a file](https://forums.swift.org/t/what-s-the-recommended-way-to-memory-map-a-file/19113) - `mappedIfSafe` vs `alwaysMapped` discussion
- [Swift Forums: callAsyncJavaScript security](https://forums.swift.org/t/proper-security-when-evaluating-javascript-from-within-swift-code-using-callasyncjavascript/54123) - Typed arguments as security best practice

### Tertiary (LOW confidence)
- None -- all findings verified against primary or secondary sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All APIs are stable Apple frameworks available well within the macOS 13 deployment target. `callAsyncJavaScript` (macOS 11+) and `mappedIfSafe` (macOS 10.4+) are mature APIs.
- Architecture: HIGH - The three patterns (mapped read, byte-size chunking, typed injection) are isolated changes to well-understood code paths. Each modifies a single method.
- Pitfalls: HIGH - Primary risks are well-understood (UTF-16 vs UTF-8 measurement, signpost timing for async code). No novel failure modes.

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable APIs, 30-day validity)
