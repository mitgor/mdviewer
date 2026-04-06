# Phase 1: Correctness & Measurement Baseline - Research

**Researched:** 2026-04-03
**Domain:** WKWebView memory management, Apple Unified Logging (os_signpost), macOS performance instrumentation
**Confidence:** HIGH

## Summary

Phase 1 has two distinct work areas: (1) fixing the WKWebView retain cycle that prevents window memory from being released, and (2) adding `OSSignposter` instrumentation to the rendering pipeline so all subsequent phases have valid profiling data. Both areas use well-documented, stable Apple APIs with canonical implementation patterns.

The retain cycle is caused by `WKUserContentController.add(self, name: "firstPaint")` in `WebContentView.swift` line 31. `WKUserContentController` holds a **strong** reference to its script message handlers. Since `WebContentView` owns `webView`, which owns its `configuration`, which owns the `userContentController`, which strong-refs back to `WebContentView` -- this forms an unbreakable cycle. The canonical fix is a `WeakScriptMessageProxy` intermediary class. Additionally, `deinit` must be added to both `WebContentView` and `MarkdownWindow` to verify deallocation.

The instrumentation work uses `OSSignposter` (available macOS 13+, which matches the deployment target). Four pipeline phases need signpost intervals: file-read, cmark-parse, chunk-split, and chunk-inject. After instrumentation is in place, baseline measurements (cold launch, warm launch, peak RSS for a 10MB file) must be recorded as the reference point for all subsequent optimization work.

**Primary recommendation:** Fix the retain cycle first (it invalidates all memory measurements), then add `OSSignposter` instrumentation, then record baselines. Do not attempt any optimization in this phase -- this phase exists purely to make measurements valid.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MEM-01 | WKUserContentController retain cycle fixed -- closing a window releases all WKWebView memory | WeakScriptMessageProxy pattern (see Architecture Patterns), deinit logging for verification, removeScriptMessageHandler cleanup |
| LAUNCH-01 | os_signpost instrumentation added to measure each pipeline phase | OSSignposter API (see Standard Stack), interval placement at file-read/parse/chunk-split/chunk-inject boundaries |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: macOS 13+ (Ventura minimum). All APIs used must be available at this target.
- **No network**: All resources bundled. No external dependencies to add.
- **Read-only**: No file modification, no state persistence (beyond what AppKit provides).
- **Speed**: First content visible in <200ms.
- **Concurrency convention**: Always capture `[weak self]` in closures. Main thread dispatch for all UI mutations.
- **Memory convention**: `weak` for delegate references. `isReleasedWhenClosed = false` on NSWindow.
- **Access control**: `private` for implementation details. `final` on concrete classes.
- **MARK organization**: Use `// MARK: -` section headers per existing convention.
- **No async/await migration**: Explicitly out of scope per REQUIREMENTS.md.

## Standard Stack

### Core

| Library/API | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| `OSSignposter` | macOS 12+ (os framework) | Pipeline interval instrumentation | Apple's modern replacement for deprecated `os_signpost()` function. Zero overhead when Instruments is not attached. Appears natively in Instruments Point of Interest and custom instruments. |
| `OSLog` | macOS 12+ (os framework) | Subsystem/category for signposter | Required to initialize `OSSignposter` with a subsystem identifier. Use `OSLog(subsystem:category:)`. |
| `WKUserContentController` | macOS 10.10+ (WebKit) | Script message handler management | `removeScriptMessageHandler(forName:)` and `removeAllScriptMessageHandlers()` are the cleanup APIs needed in `deinit`. |

### Supporting

| Library/API | Version | Purpose | When to Use |
|-------------|---------|---------|-------------|
| `OSSignpostID` | macOS 12+ | Disambiguate concurrent intervals | Use `signposter.makeSignpostID()` when multiple file-open operations could overlap (concurrent window opens). |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `OSSignposter` | `os_signpost()` (C function) | Deprecated since macOS 12. Still works but Apple docs recommend `OSSignposter`. Since deployment target is macOS 13, use the modern API. |
| `OSSignposter` | `CFAbsoluteTimeGetCurrent()` manual timing | No Instruments integration, no zero-overhead property, no structured intervals. Never use for pipeline profiling. |
| WeakScriptMessageProxy | `WKScriptMessageHandlerWithReply` | Different protocol, adds unnecessary complexity. The proxy pattern is simpler and canonical. |

**No installation needed** -- all APIs are in system frameworks already linked by the project (os, WebKit).

## Architecture Patterns

### Pattern 1: WeakScriptMessageProxy (MEM-01)

**What:** A lightweight intermediary class that conforms to `WKScriptMessageHandler`, holds a `weak` reference to the real handler, and forwards messages. Breaks the retain cycle because `WKUserContentController` strong-refs the proxy, not the view.

**When to use:** Any time a class adds itself as a `WKScriptMessageHandler` via `contentController.add(self, ...)`.

**Example:**
```swift
// Source: Canonical WebKit pattern, documented at tigi44.github.io and multiple Apple Developer Forums posts
private class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
```

**Usage in WebContentView.init:**
```swift
// BEFORE (retain cycle):
contentController.add(self, name: "firstPaint")

// AFTER (no retain cycle):
contentController.add(WeakScriptMessageProxy(delegate: self), name: "firstPaint")
```

**Cleanup in deinit:**
```swift
deinit {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")
}
```

### Pattern 2: OSSignposter Pipeline Instrumentation (LAUNCH-01)

**What:** Structured interval markers that appear in Instruments when profiling. Each pipeline phase (file-read, parse, chunk-split, chunk-inject) gets a begin/end pair.

**When to use:** Around each discrete stage of the rendering pipeline.

**Example:**
```swift
import os

// Define once, shared across the app
private let signposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)

// In MarkdownRenderer.renderFullPage(fileURL:template:):
func renderFullPage(fileURL: URL, template: SplitTemplate) -> RenderResult? {
    let spID = signposter.makeSignpostID()

    // File read interval
    let readState = signposter.beginInterval("file-read", id: spID)
    guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
        signposter.endInterval("file-read", readState)
        return nil
    }
    signposter.endInterval("file-read", readState)

    // Parse interval
    let parseState = signposter.beginInterval("parse", id: spID)
    let html = parseMarkdownToHTML(markdown)
    signposter.endInterval("parse", parseState)

    // Chunk-split interval
    let chunkState = signposter.beginInterval("chunk-split", id: spID)
    let (processed, hasMermaid) = processMermaidBlocks(html)
    let chunks = chunkHTML(processed)
    signposter.endInterval("chunk-split", chunkState)

    let firstChunk = chunks.first ?? ""
    let remaining = Array(chunks.dropFirst())
    let page = template.prefix + firstChunk + template.suffix
    return RenderResult(page: page, remainingChunks: remaining, hasMermaid: hasMermaid)
}

// In WebContentView, for chunk-inject:
private func injectRemainingChunks() {
    let state = signposter.beginInterval("chunk-inject")
    // ... injection code ...
    signposter.endInterval("chunk-inject", state)
}
```

### Pattern 3: deinit Verification Logging

**What:** Add `deinit` to `WebContentView` and `MarkdownWindow` with `os_log` or `print` output to confirm deallocation occurs when windows close.

**Example:**
```swift
// In WebContentView:
deinit {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")
    #if DEBUG
    print("[WebContentView] deinit - \(ObjectIdentifier(self))")
    #endif
}

// In MarkdownWindow:
deinit {
    #if DEBUG
    print("[MarkdownWindow] deinit - \(ObjectIdentifier(self))")
    #endif
}
```

### Pattern 4: hasProcessedFirstPaint Guard

**What:** Boolean flag preventing double-processing of the `firstPaint` message if `DOMContentLoaded` fires more than once.

**Example:**
```swift
private var hasProcessedFirstPaint = false

func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
) {
    if message.name == "firstPaint", !hasProcessedFirstPaint {
        hasProcessedFirstPaint = true
        delegate?.webContentViewDidFinishFirstPaint(self)
        injectRemainingChunks()
        if hasMermaid {
            loadAndInitMermaid()
        }
    }
}
```

### Recommended File Changes

```
MDViewer/
  WebContentView.swift      # WeakScriptMessageProxy, deinit, hasProcessedFirstPaint guard
  MarkdownRenderer.swift     # OSSignposter intervals for file-read, parse, chunk-split
  MarkdownWindow.swift       # deinit logging
  AppDelegate.swift          # (minimal) possibly signpost for overall open-to-paint
```

No new files needed. All changes are modifications to existing files.

### Anti-Patterns to Avoid

- **Adding `removeScriptMessageHandler` anywhere other than `deinit`:** If called earlier (e.g., in a cleanup method), the handler stops receiving messages while the view is still alive. Only clean up in `deinit`.
- **Using `os_signpost()` C function:** Deprecated. Use `OSSignposter` class methods.
- **Putting signposter as an instance variable on MarkdownRenderer:** The renderer is stateless by design. Use a module-level `private let` instead.
- **Optimizing anything in this phase:** This phase is measurement-only. Do not change `String(contentsOf:)` to `Data(contentsOf:)`, do not change `evaluateJavaScript` to `callAsyncJavaScript`, do not implement N-chunk splitting. Those are Phase 2.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Retain cycle breaking | Manual ref counting or `weak` property on self | `WeakScriptMessageProxy` class | The proxy pattern is the canonical solution for WKScriptMessageHandler. Apple's API design forces this -- there is no built-in weak option. |
| Performance timing | `Date()` or `CFAbsoluteTimeGetCurrent()` | `OSSignposter` intervals | Manual timing has no Instruments integration, no structured intervals, and adds measurement overhead. OSSignposter is zero-cost when not profiling. |
| Deallocation verification | Memory graph debugger only | `deinit` + `print` + Instruments Allocations | `deinit` logging is automatable and appears in console during development. Instruments confirms in production-like conditions. Both are needed. |

## Common Pitfalls

### Pitfall 1: Retain Cycle Not Actually Fixed

**What goes wrong:** Developer adds `removeScriptMessageHandler` in `deinit` but `deinit` never runs because the retain cycle prevents it. The cleanup code is dead code.
**Why it happens:** `deinit` only runs when the object is deallocated. If the retain cycle still exists, `deinit` is never called.
**How to avoid:** The fix is the `WeakScriptMessageProxy` -- it breaks the cycle so `deinit` CAN run. The `removeScriptMessageHandler` in `deinit` is belt-and-suspenders cleanup, not the actual fix.
**Warning signs:** After implementing the fix, close a window and check that "deinit" prints appear in the console. If they don't, the cycle is still present.

### Pitfall 2: OSSignposter Intervals Not Visible in Instruments

**What goes wrong:** Signpost intervals are added but nothing appears in the Instruments "Points of Interest" or "os_signpost" instruments.
**Why it happens:** The subsystem string doesn't match what Instruments is filtering for, or the app is run from Xcode debug mode which can buffer log output differently.
**How to avoid:** Use the exact bundle ID as the subsystem (`"com.mdviewer.app"`). In Instruments, use the "os_signpost" instrument (not "Points of Interest" which shows events, not intervals). Profile with the "Time Profiler" or custom "os_signpost" template.
**Warning signs:** Instruments shows the app process but the signpost track is empty.

### Pitfall 3: Measuring RSS Incorrectly

**What goes wrong:** Using Activity Monitor or `task_info` to read RSS immediately after closing a window and concluding memory is not freed.
**Why it happens:** WKWebView runs in a separate process (`com.apple.WebKit.WebContent`). The web process may linger for a few seconds after the last webview is destroyed. Also, macOS aggressively caches freed pages in RSS until memory pressure forces reclamation.
**How to avoid:** Use Instruments Allocations instrument with "Record reference counts" to track object lifetimes. For RSS validation, open and close 10 windows in sequence and verify sustained RSS does not grow (allowing for WKWebView process pool warm cache).
**Warning signs:** RSS drops partially but not to baseline after closing one window. This is expected due to WKWebView process pooling. The success criterion is that 10 sequential open/close cycles do NOT grow sustained RSS.

### Pitfall 4: Forgetting the Window Array Cleanup Interaction

**What goes wrong:** The retain cycle fix works, but the `NotificationCenter` observer in `AppDelegate.displayResult` holds a reference to the window via the closure, preventing cleanup.
**Why it happens:** The `willCloseNotification` observer closure captures `self` (AppDelegate) weakly but captures `closedWindow` from the notification strongly during removal.
**How to avoid:** Review the existing cleanup path in `AppDelegate.swift` lines 138-145. The current implementation uses `[weak self]` and gets `closedWindow` from the notification object (not captured), so it should be correct. Verify by checking deinit fires after window close AND after removal from `windows` array.
**Warning signs:** `MarkdownWindow.deinit` does not print after closing a window even though `WebContentView.deinit` does.

### Pitfall 5: developerExtrasEnabled Gate Breaks Debugging

**What goes wrong:** Gating `developerExtrasEnabled` behind `#if DEBUG` means you cannot use Web Inspector when running a Release build for profiling.
**Why it happens:** Instruments profiling should use Release builds for accurate measurements, but Release builds don't have DEBUG defined.
**How to avoid:** This is a tradeoff. For this phase, keep `developerExtrasEnabled` gated behind `#if DEBUG` as specified in CONCERNS.md. When profiling in Instruments, the Web Inspector is not needed -- use the native Instruments tools instead.
**Warning signs:** None -- this is a known tradeoff, not a bug.

## Code Examples

### Complete WeakScriptMessageProxy Implementation

```swift
// Source: Canonical pattern from WebKit community, verified against Apple docs
// Place as a private class inside WebContentView.swift

private class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
```

### Complete OSSignposter Setup

```swift
// Source: Apple Developer Documentation - OSSignposter
// Place at file scope in MarkdownRenderer.swift (and import in WebContentView.swift)

import os

let renderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
```

### Baseline Measurement Recording

After instrumentation is in place, record these measurements using Instruments:

1. **Cold launch:** Profile with App Launch template after `sudo purge`. Measure time from process start to first `firstPaint` message.
2. **Warm launch:** Profile after one previous launch in the same boot session. Same measurement point.
3. **Peak RSS for 10MB file:** Use Allocations instrument. Open a 10MB markdown file, record peak "All Heap Allocations" and "Dirty Size" columns.
4. **Sustained RSS after 10 windows:** Open and close 10 windows sequentially. Record RSS after last close (allow 2-3 seconds for WKWebView process cleanup).

Record values in a markdown table in the phase directory for reference by subsequent phases.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `os_signpost()` C function | `OSSignposter` class | macOS 12 / WWDC 2021 | Swift-native API, better ergonomics, same Instruments integration |
| Manual `removeScriptMessageHandler` in `viewWillDisappear` | `WeakScriptMessageProxy` pattern | Always (pattern, not API change) | Proxy is cleaner -- no lifecycle method dependency |

**Deprecated/outdated:**
- `os_signpost()` free function: Still compiles but Apple docs recommend `OSSignposter`. Since macOS 13 is the floor, use the modern API exclusively.

## Open Questions

1. **Where to store baseline measurements**
   - What we know: Values need to be recorded for Phase 2/3 reference
   - What's unclear: File format and location
   - Recommendation: Create a `01-BASELINES.md` file in the phase directory with a simple markdown table. This is documentation, not code.

2. **Signpost for overall open-to-paint timing**
   - What we know: The four intervals (file-read, parse, chunk-split, chunk-inject) cover the pipeline stages
   - What's unclear: Whether to also add a parent interval spanning the entire `openFile` -> `firstPaint` flow
   - Recommendation: Add it. A parent interval from `AppDelegate.openFile` to `webContentViewDidFinishFirstPaint` provides the end-to-end number that maps directly to the "sub-200ms" requirement. Use a different signpost name like `"open-to-paint"`.

## Sources

### Primary (HIGH confidence)
- [OSSignposter | Apple Developer Documentation](https://developer.apple.com/documentation/os/ossignposter) - API surface, availability (macOS 12+)
- [removeScriptMessageHandler(forName:) | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkusercontentcontroller/removescriptmessagehandler(forname:)) - cleanup API
- [removeAllScriptMessageHandlers() | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkusercontentcontroller/removeallscriptmessagehandlers()) - bulk cleanup API
- [OSSignpostID | Apple Developer Documentation](https://developer.apple.com/documentation/os/ossignpostid) - concurrent interval disambiguation

### Secondary (MEDIUM confidence)
- [WKWebView ScriptMessageHandler Memory Leak - SIDESTEP (tigi44)](https://tigi44.github.io/ios/iOS,-Objective-c-WKWebView-ScriptMessageHandler-Memory-Leak/) - WeakScriptMessageProxy pattern with Objective-C and Swift examples
- [Measuring performance with os_signpost - Donny Wals](https://www.donnywals.com/measuring-performance-with-os_signpost/) - practical signpost usage patterns
- [Measuring app performance in Swift - Swift with Majid](https://swiftwithmajid.com/2022/05/04/measuring-app-performance-in-swift/) - OSSignposter usage examples

### Tertiary (LOW confidence)
- None -- all findings verified against primary or secondary sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - `OSSignposter` and `WKUserContentController` are stable Apple APIs, deployment target (macOS 13) exceeds availability requirements (macOS 12 / macOS 10.10)
- Architecture: HIGH - `WeakScriptMessageProxy` is the canonical, universally-recommended pattern for this exact problem. No ambiguity.
- Pitfalls: HIGH - Retain cycle is a confirmed existing bug in the codebase (CONCERNS.md documents it). All pitfalls are well-understood WebKit behaviors.

**Research date:** 2026-04-03
**Valid until:** 2026-05-03 (stable APIs, 30-day validity)
