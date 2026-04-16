---
phase: 08-streaming-pipeline
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - MDViewer/MarkdownRenderer.swift
  - MDViewer/WebContentView.swift
  - MDViewer/AppDelegate.swift
  - MDViewerTests/MarkdownRendererTests.swift
findings:
  critical: 0
  warning: 4
  info: 3
  total: 7
status: issues_found
---

# Phase 08: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

The streaming pipeline implementation is well-structured. The chunked C callback, `Unmanaged` pointer bridge, `StreamingRenderContext`, and the `assemblyBuffer` reuse pattern are all sound. The main-thread dispatch discipline is correct — first chunk and `onComplete` both marshal to main before touching UI state.

Four warnings were found: a race window in the streaming handoff between `onFirstChunk` and `onComplete`, a `setRemainingChunks` call-after-`loadContent` ordering assumption that can silently misfire, unsafe `assemblyBuffer` reuse across the two overloads of `renderStreaming`, and a signpost interval that can be double-ended. Three info items cover duplicate extension-lookup work, a dead `displayResult` method, and force-try usage in tests.

---

## Warnings

### WR-01: Race window — `streamContentView` captured across two DispatchQueue.main.async hops

**File:** `MDViewer/AppDelegate.swift:155-196`

**Issue:** `streamContentView` is a `var` declared on the background thread stack and written inside the `onFirstChunk` closure (which is dispatched to main). It is then read inside the `onComplete` closure (also dispatched to main). Because both closures are dispatched to `DispatchQueue.main.async` — not synchronously executed — the two blocks are queued independently. If `onComplete` fires on the background thread before `onFirstChunk`'s main-thread block has had a chance to run (possible on a fast render of a single-chunk file), `streamContentView` will still be `nil` when `onComplete`'s main-thread block reads it. `setRemainingChunks` is then silently dropped for that window.

In practice the C renderer calls both callbacks synchronously on the same background thread (the `cmark_render_html_chunked` call completes before `renderStreaming` returns), so the ordering of the two `DispatchQueue.main.async` blocks is FIFO. However, the code relies on this undocumented sequencing property. A comment is the minimum fix; a safer fix eliminates the captured `var` entirely:

```swift
// In onFirstChunk closure — capture the view in a local and return it
// so onComplete can reference the same object without a shared var.
onFirstChunk: { page in
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let contentView = self.webViewPool.dequeue() ?? WebContentView(frame: .zero)
        // ... setup ...
        contentView.loadContent(page: page, remainingChunks: [], hasMermaid: false)
        // Pass the view identity into onComplete via a local capture, not a shared var
    }
},
onComplete: { [capturedContentView] remainingChunks, hasMermaid in
    DispatchQueue.main.async {
        capturedContentView?.setRemainingChunks(remainingChunks, hasMermaid: hasMermaid)
    }
}
```

Since the current `renderStreaming` API doesn't support returning a value from `onFirstChunk`, the safest minimal fix is to add a comment making the sequencing assumption explicit and guard against `nil` (which is already done via optional chaining on line 192, but a comment explaining *why* it can be nil — and why it's safe — is missing).

---

### WR-02: `setRemainingChunks` can be called before `loadContent` if `onComplete` fires very fast

**File:** `MDViewer/WebContentView.swift:83-95`

**Issue:** `setRemainingChunks` checks `hasProcessedFirstPaint` to decide whether to inject immediately or defer. However, `hasProcessedFirstPaint` is reset to `false` inside `loadContent` (line 75). If `onComplete` dispatches to main and `setRemainingChunks` is called before `loadContent` has been called on the same view (e.g., due to reordering or pool reuse), the chunks will be stored but `hasProcessedFirstPaint` is `false` so they won't be injected immediately — which is the correct path. However, if `loadContent` is then called on a *different* view (pool gave a different instance), those chunks are now stranded in the wrong view. This is the same underlying issue as WR-01: the mapping between `streamContentView` and the chunks is implicit.

A concrete guard would make the contract explicit:

```swift
func setRemainingChunks(_ chunks: [String], hasMermaid: Bool) {
    // Must be called after loadContent on the same view.
    // hasProcessedFirstPaint resets in loadContent; if it is still false
    // here, the firstPaint handler will pick up whatever was stored.
    self.remainingChunks = chunks
    self.hasMermaid = hasMermaid
    if hasProcessedFirstPaint {
        injectRemainingChunks()
        if hasMermaid { loadAndInitMermaid() }
    }
}
```

The code is already structured this way; what's missing is a precondition or assertion that `self.remainingChunks` was empty (i.e., `loadContent` was called first):

```swift
assert(self.remainingChunks.isEmpty,
    "setRemainingChunks called before loadContent cleared previous chunks")
```

---

### WR-03: `assemblyBuffer` is an instance-level mutable buffer shared between `renderStreaming(markdown:...)` and `renderStreaming(fileURL:...)` — neither is re-entrant-safe, but `renderStreaming(fileURL:...)` calls the other one

**File:** `MDViewer/MarkdownRenderer.swift:116-129`, `139-213`, `216-243`

**Issue:** `assemblyBuffer` is noted in its own comment as "Not thread-safe for concurrent calls on the same renderer instance." `AppDelegate` holds a single `MarkdownRenderer` instance (`private let renderer = MarkdownRenderer()`) and opens multiple files concurrently via `DispatchQueue.global(qos: .userInitiated).async`. Each concurrent `openFile` call captures `let renderer = self.renderer` and calls `renderer.renderStreaming(fileURL:...)`. If two files are opened simultaneously, two background threads will call `assemblyBuffer.removeAll(keepingCapacity: true)` on the same array concurrently, which is a data race.

The comment on `assemblyBuffer` documents the constraint but AppDelegate does not enforce it — it intentionally uses a shared renderer for cmark extension caching (CMARK-05). The options:

1. Make `assemblyBuffer` thread-local (via `@TaskLocal` or a local variable inside the method).
2. Use a per-call local buffer instead of an instance property (removes the optimization but eliminates the hazard):

```swift
func assembleFirstPage(template: SplitTemplate, chunk: String) -> String {
    var buf: [UInt8] = []
    buf.reserveCapacity(template.prefix.utf8.count + chunk.utf8.count + template.suffix.utf8.count)
    buf.append(contentsOf: template.prefix.utf8)
    buf.append(contentsOf: chunk.utf8)
    buf.append(contentsOf: template.suffix.utf8)
    return String(decoding: buf, as: UTF8.self)
}
```

3. Protect with a lock (adds latency on the hot path).

Option 2 is the safest given the sequential rendering constraint is already broken in practice (two files opened at once each call the method).

---

### WR-04: Signpost interval `"launch-to-paint"` can be ended twice

**File:** `MDViewer/AppDelegate.swift:39-43`, `116-121`

**Issue:** The guard in both end-sites is `!hasCompletedFirstLaunchPaint` followed by setting `hasCompletedFirstLaunchPaint = true`. Both code paths run on the main thread, so there is no data race. However, the 5-second timeout on line 39 uses `DispatchQueue.main.asyncAfter`. If `webContentViewDidFinishFirstPaint` fires at the same wall-clock tick as the timer fires (e.g., the first paint arrives within the same run-loop turn as the timer's deadline), both can read `hasCompletedFirstLaunchPaint == false` before either sets it to `true` — this is safe because both are on the main thread (serialized), but it's fragile since the 5-second block mutates `hasCompletedFirstLaunchPaint` *after* checking it and the two blocks are not atomic. On the main thread this is fine; adding a comment to that effect would prevent future readers from extracting this to a concurrent context.

Additionally, if no file is ever opened, the signpost interval begun in `main.swift` (line 8) is ended by the 5-second timeout — but the interval was labeled `"launch-to-paint"` with `launchSignpostState` from `main.swift`, while the `appSignposter` in `AppDelegate` has a *different* `OSSignposter` instance (line 6-9 of `AppDelegate.swift`). Both signposters share the same subsystem/category string but are distinct objects. `launchSignposter.endInterval` and `appSignposter.endInterval` will each create separate Instruments timeline entries. This is not a crash, but it means the "launch-to-paint" interval and all "open-to-paint" intervals appear as separate Instruments tracks rather than a unified view. This is a telemetry accuracy issue, not a correctness bug per se, but it can produce misleading profiling data.

---

## Info

### IN-01: Extension lookup duplicated in `render` — bypasses `cachedExtList`

**File:** `MDViewer/MarkdownRenderer.swift:68-73`

**Issue:** `render(markdown:)` calls `cmark_find_syntax_extension(name)` inside a loop (lines 68-73) for each invocation, then attaches them to the parser. The `cachedExtList` built in `init()` is passed to `cmark_render_html_chunked` (line 87) but the parser-attachment step re-does the lookup. This means every render call performs 4 `cmark_find_syntax_extension` lookups even though the extension pointers are stable after `cmark_gfm_core_extensions_ensure_registered()`. The same pattern appears in `renderStreaming(markdown:...)` (lines 155-160). This does not affect correctness, but the optimization intent of CMARK-05 (cached extension pointers) is only half-fulfilled.

**Fix:** Cache the extension pointers at `init` time and use them for parser attachment, the same way `cachedExtList` is used for rendering:

```swift
private let cachedExtPointers: [OpaquePointer]  // [UnsafeMutablePointer<cmark_syntax_extension>]

init() {
    cmark_gfm_core_extensions_ensure_registered()
    let extNames = ["table", "strikethrough", "autolink", "tasklist"]
    cachedExtPointers = extNames.compactMap { cmark_find_syntax_extension($0) }
    // build cachedExtList from cachedExtPointers ...
}

// In render / renderStreaming:
for ext in cachedExtPointers {
    cmark_parser_attach_syntax_extension(parser, ext)
}
```

---

### IN-02: `displayResult(_:for:paintState:)` is dead code

**File:** `MDViewer/AppDelegate.swift:213-238`

**Issue:** `displayResult(_:for:paintState:)` is defined as a `private` method (line 213) but is never called. The streaming pipeline (`openFile`) now handles all window creation inline. This method appears to be a leftover from the pre-streaming batch render path.

**Fix:** Remove the method, or keep it with an explicit `// Legacy batch path — retained for reference` comment if removal is not safe yet.

---

### IN-03: Force-try (`try!`) in test helper writes

**File:** `MDViewerTests/MarkdownRendererTests.swift:91`, `128`, `324`

**Issue:** `try!` is used in test setup to write temporary files (e.g., `try! "# File Test\n\nContent".write(to: tmpFile, ...)`). If the write fails (e.g., disk full, bad temp path), the test crashes the entire test runner process rather than failing the individual test with a useful message.

**Fix:** Use `XCTAssertNoThrow` or a `do/catch` with `XCTFail`:

```swift
do {
    try "# File Test\n\nContent".write(to: tmpFile, atomically: true, encoding: .utf8)
} catch {
    XCTFail("Failed to write temp file: \(error)")
    return
}
```

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
