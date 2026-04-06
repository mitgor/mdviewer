# Domain Pitfalls: macOS Markdown Viewer Performance Optimization

**Domain:** macOS AppKit + WKWebView document viewer
**Researched:** 2026-04-03
**Project:** MDViewer — sub-100ms launch, large file support, memory reduction

---

## Critical Pitfalls

These mistakes cause rewrites, persistent memory leaks, or regressions that invalidate the optimization work itself.

---

### Pitfall 1: Optimizing Without Measuring First

**What goes wrong:** Engineers guess where the bottleneck is (e.g., "cmark must be slow") and spend days
optimizing code that contributes <2ms to launch time, while the real bottleneck (e.g., WKWebView
initialization at 80ms) goes untouched.

**Why it happens:** Launch time feels like a parsing/rendering problem, but on macOS the dominant costs
are often process startup, dyld, and web view process spawning — none of which are visible without
Instruments.

**Consequences:** Sub-100ms target missed. Micro-optimizations accumulate technical debt while the
needle does not move. Regressions introduced in "optimized" code that was never the bottleneck.

**Prevention:**
- Profile with Xcode's Time Profiler and App Launch template in Instruments before writing any
  optimization code.
- Establish a baseline measurement for each phase: cold launch time, warm launch time, peak RSS,
  and sustained RSS after rendering a 10MB file.
- Do not commit a change labeled "performance" without a before/after measurement attached.

**Warning signs:**
- An optimization ticket has no baseline measurement cited.
- A PR description says "should be faster" instead of "reduced launch time from X to Y ms."
- The optimization targets cmark parsing — it is already C-speed and benchmarks at <10ms for large
  files per the project's own notes.

**Phase relevance:** Every phase — but most dangerous in Phase 1 (launch time) where guessing is
most tempting.

---

### Pitfall 2: The WKWebView Retain Cycle via Script Message Handler

**What goes wrong:** `contentController.add(self, name: "firstPaint")` passes a strong reference to
`WebContentView`. `WKUserContentController` holds that reference strongly. `webView` retains
`config.userContentController`. Result: a reference cycle that prevents `WebContentView` and its
associated `WKWebView` from ever being deallocated. Every closed window leaks the full WKWebView
process allocation.

**Why it happens:** The WebKit API accepts a protocol (`WKScriptMessageHandler`) rather than a
closure, making the strong capture invisible. There is no compiler warning.

**Consequences:** Per-window memory does not decrease when windows are closed. On a session where
ten files are opened and closed, RSS grows monotonically. This directly contradicts the "reduce
per-window memory footprint" milestone goal. CONCERNS.md already flags this (Fragile Areas, line 109).

**Prevention:** Use a weak-proxy wrapper before any other memory work:

```swift
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
// Registration:
contentController.add(WeakScriptMessageProxy(self), name: "firstPaint")
```

Add a `deinit` to `WebContentView` with an assertion or log statement to confirm deallocation is
happening. This should be the very first code change in the memory-reduction phase.

**Warning signs:**
- No `deinit` in `WebContentView` or `MarkdownWindow`.
- Instruments Memory Graph shows `WKWebView` instances accumulating after window close.
- RSS climbs with each file opened even after all windows are closed.

**Phase relevance:** Memory reduction phase — must be fixed before any per-window RSS measurements
are valid.

---

### Pitfall 3: Treating `evaluateJavaScript` as Free for Large Payloads

**What goes wrong:** Large HTML chunks (the "remaining chunk" described in CONCERNS.md) are
passed through `evaluateJavaScript` as a single massive string. This crosses the Swift/WebKit IPC
boundary synchronously on the main thread. For a 5MB second chunk, parsing the JS string alone
can block the main thread for hundreds of milliseconds — longer than the entire target launch
budget.

**Why it happens:** The API looks simple. Developers assume the string serialization cost is
negligible because they tested with small documents.

**Consequences:** Spinning beachball on large files. Main thread stalls visible in Instruments as
long `evaluateJavaScript` calls. Progressive rendering produces one instant first chunk and then
a long freeze before the second chunk appears — the opposite of "progressive."

**Prevention:**
- Use `callAsyncJavaScript(_:arguments:in:in:completionHandler:)` (macOS 11+) with typed
  parameters. WebKit handles JSON serialization of typed Swift values, bypassing manual string
  escaping entirely and enabling async execution in the web process.
- Implement true N-chunk splitting in `MarkdownRenderer.chunkHTML`. Aim for chunks ≤50KB of
  rendered HTML. Spread injection over `setTimeout(..., 0)` or `requestAnimationFrame` ticks in
  JavaScript so the browser renderer can paint between injections.
- Measure: the existing JS in `WebContentView.swift` already staggers chunks with `i * 16ms`.
  The problem is that the Swift side still sends one enormous payload. Fix the Swift split first,
  then verify the stagger works.

**Warning signs:**
- `evaluateJavaScript` call appears in a Time Profiler trace taking >10ms.
- The "remaining chunk" string is larger than 100KB.
- Manual escaping loop for backtick/dollar-sign still present in `injectRemainingChunks`
  (CONCERNS.md line 119).

**Phase relevance:** Large file support phase and N-chunk progressive rendering phase.

---

### Pitfall 4: Loading Mermaid via the JS Bridge Instead of a Script Tag

**What goes wrong:** `loadAndInitMermaid()` reads 3MB of JavaScript from disk synchronously on
the main thread and then passes it through `evaluateJavaScript`. Even with the static cache,
every new window that contains a diagram pays the 3MB IPC cost through the Swift/WebKit bridge.

**Why it happens:** The bridge approach was a quick solution. The `<script src>` alternative
requires knowing that `loadHTMLString(baseURL:)` resolves relative URLs from the bundle, which is
non-obvious.

**Consequences:** Each diagram window costs an extra ~50–100ms for the bridge call. Memory
overhead: the 3MB string lives in Swift heap (`mermaidJSLoaded` static) AND in the WebKit process
after injection.

**Prevention:** Replace the bridge injection with a `<script src="mermaid.min.js">` tag in
`template.html`. Since `loadHTMLString` already uses `Bundle.main.resourceURL` as the base URL
(PROJECT.md, line 66: "loadHTMLString over loadFileURL"), a relative `src` resolves correctly.
WebKit's resource caching then handles the 3MB file natively across all windows.

**Warning signs:**
- `mermaidJSLoaded` static var still present in `WebContentView.swift`.
- Instruments shows a large string allocation in `loadAndInitMermaid` per window open.
- CONCERNS.md already flags this explicitly (Performance Bottlenecks, line 87).

**Phase relevance:** Memory reduction phase. Fix this before measuring per-window RSS or it
inflates baseline numbers.

---

### Pitfall 5: Using `String(contentsOf:)` for 10MB+ Files

**What goes wrong:** `String(contentsOf: url, encoding: .utf8)` loads the entire file into a
contiguous UTF-8 Swift String. For a 10MB markdown file this allocates ~10–30MB of heap (Swift
String has overhead over raw bytes). For very large files (100MB) this has been observed to
allocate 300MB peak RSS due to intermediate buffer allocations during encoding conversion.

**Why it happens:** It is the idiomatic one-liner. The memory spike is invisible during testing
with small files.

**Consequences:** "Stream large files (10MB+) without loading entire file into memory" is a stated
milestone goal. A naive `String(contentsOf:)` replacement approach completely defeats this goal.
Worse, the spike can trigger macOS memory pressure events mid-load, causing system-wide
performance degradation.

**Prevention:**
- Read the file as `Data(contentsOf: url, options: .mappedIfSafe)`. `mappedIfSafe` uses
  `mmap(2)` on macOS, making the file access demand-paged. The OS pages in only the bytes
  actually accessed. This is the correct primitive for large read-only files on macOS.
- Pass the `Data` buffer directly to cmark-gfm's C API
  (`cmark_parse_document(data, length, options)`) without ever creating a Swift `String` from
  the entire file.
- For truly streaming behavior (cmark-gfm supports a parser feed API via `cmark_parser_feed`),
  read in 256KB chunks with `FileHandle.read(upToCount:)` and feed them incrementally.

**Warning signs:**
- `String(contentsOf:)` anywhere in the file-loading path.
- `MarkdownRenderer` accepts a `String` parameter — this forces the caller to have already loaded
  the entire file.
- Peak RSS in Allocations instrument spikes proportionally to file size at load time.

**Phase relevance:** Large file support phase. This is the first thing to address in that phase.

---

## Moderate Pitfalls

These cause measurable regressions or wasted effort but do not require a full redesign.

---

### Pitfall 6: Conflating Warm and Cold Launch in Measurements

**What goes wrong:** A developer measures launch time after the app was recently closed. macOS
has cached the binary, dyld shared cache is warm, and the WebKit process may already have a
prepared render process. They report "60ms launch" and declare victory. Real users on first open
of the day see 200ms+.

**Why it happens:** Convenience. Cold launch requires rebooting or cache flush
(`purge` command or memory pressure simulation).

**Prevention:**
- Always measure cold launch using Xcode's App Launch instrument or by running `purge` between
  measurements.
- Report both cold and warm numbers in every performance PR.
- The sub-100ms target should refer to warm launch. Cold launch on macOS 13+ for a WKWebView app
  is typically 150–300ms and is largely outside the app's control (dyld, WebKit process spawn).
  Document this distinction in the milestone definition.

**Warning signs:**
- PR claims sub-100ms without specifying warm vs. cold.
- Measurements taken in Xcode debug build (debug has 2-3x slower startup than release).

**Phase relevance:** Launch time phase — establish measurement discipline before first optimization.

---

### Pitfall 7: Pre-Allocating WKWebView at Startup to Amortize Init Cost

**What goes wrong:** The temptation is to create a hidden WKWebView at `applicationDidFinishLaunching`
so it is "warm" when the first file is opened. This is a known technique (WebViewWarmUper pattern)
and saves 50–100ms of first-open latency, but it permanently adds the WKWebView process overhead
to every launch — including launches where the user just runs `mdviewer file.md` and the webview
is needed immediately anyway.

**Why it happens:** The technique is recommended for app scenarios with dynamic webviews, but
MDViewer always opens exactly one webview per launch. Pre-allocation is redundant.

**Consequences:** RSS at startup increases by the webview process overhead (~50MB) for all
launches. Startup time is not actually reduced because the webview would have been allocated on
the next runloop tick anyway when the file opens.

**Prevention:** Do not pre-warm. Instead, reduce the time between `applicationWillFinishLaunching`
and `loadHTMLString` by ensuring `template.html` is pre-loaded on a background queue
(`ensureTemplateLoaded()` already does this) and by deferring non-critical setup (autosave key
registration, cascading logic) until after the first paint signal fires.

**Warning signs:**
- Any `WKWebView()` or `WebContentView()` allocation in `AppDelegate.applicationDidFinishLaunching`
  that is not directly tied to a file being opened.

**Phase relevance:** Launch time phase.

---

### Pitfall 8: All Windows Sharing a Single `frameSaveKey`

**What goes wrong:** `frameSaveKey = "MDViewerWindowFrame"` is a static constant. When multiple
windows are open, the last-closed window's frame overwrites all previous saves. On next launch,
all windows open at the position of the last closed window rather than cascading from their
individual saved positions.

**Why it happens:** Simple implementation that works for the single-window case.

**Consequences:** Confusing UX when opening multiple files; every window opens at the same
position. CONCERNS.md already flags this (Tech Debt, line 16).

**Prevention:** Use a per-file autosave name derived from the file URL:
```swift
let key = "MDViewerFrame-" + fileURL.path.hashValue.description
window.setFrameAutosaveName(key)
```
Or, for simplicity, document the last-write-wins behavior and rely on `cascade(from:)` for
multi-window positioning instead of frame restoration.

**Warning signs:**
- `frameSaveKey` is `static let` (current state).
- `loadSavedFrame()` returns `nil` unconditionally (current state — CONCERNS.md line 10).

**Phase relevance:** Window management phase. Do not attempt frame persistence until the single-key
problem is resolved, or persistence will actively create incorrect behavior.

---

### Pitfall 9: Skipping `@MainActor` Annotations on WKWebView-Adjacent Code

**What goes wrong:** Swift 6 strict concurrency checking (or `SWIFT_STRICT_CONCURRENCY=complete`
in Xcode 16+) will flag every access to `mermaidJSLoaded`, `mermaidJS`, and `remainingChunks`
as potential data races unless they are constrained to an actor. CONCERNS.md flags this
(Fragile Areas, line 124): the statics are main-thread–only in practice but are not annotated.

**Why it happens:** The current code works under Swift 5 concurrency rules. Developers defer
annotation work because "it compiles."

**Consequences:** When strict concurrency is enabled (likely as part of a Swift 6 migration or
Xcode upgrade), hundreds of warnings appear simultaneously, making it hard to distinguish real
races from annotation gaps. A future developer moves `loadAndInitMermaid` to a background queue
during optimization and silently introduces a data race.

**Prevention:** Annotate `WebContentView` with `@MainActor` now. Propagate actor annotations
during any refactor that touches the webview/rendering pipeline. Treat compiler concurrency
warnings as errors in CI.

**Warning signs:**
- No `@MainActor` annotation on `WebContentView` or `MarkdownRenderer`.
- `mermaidJSLoaded` and `mermaidJS` are `static var` without actor isolation.

**Phase relevance:** Any phase that refactors `WebContentView` — annotate first, then refactor.

---

### Pitfall 10: Fixing `isReleasedWhenClosed` Without Fixing the Delegate Chain

**What goes wrong:** Setting `isReleasedWhenClosed = false` on `MarkdownWindow` is the correct
baseline for ARC-managed windows. However, AppKit will still retain windows that are "ordered in."
Closing a window via the close button calls `performClose` → `close`, which orders out the window
and triggers the `isReleasedWhenClosed` path. But if `windowWillClose` delegates are not properly
nilled out, the window delegate chain can keep the window alive through a separate strong reference.

**Why it happens:** Multiple overlapping strong-reference paths in AppKit's window lifecycle.
Fixing one path (the `isReleasedWhenClosed` flag) while leaving another (the delegate reference)
unchanged produces misleading Instruments readings where the window appears closed but is alive.

**Prevention:**
- Verify deallocation with a `deinit` log on both `MarkdownWindow` and `WebContentView`.
- Check `window.delegate` and `webView.navigationDelegate` — both should be `weak` references.
- Confirm in Instruments Memory Graph that after closing all windows, zero `WKWebView` and
  zero `MarkdownWindow` instances remain.

**Warning signs:**
- `window.delegate = self` where `self` is stored with a strong reference.
- No `deinit` in any window or view class.

**Phase relevance:** Memory reduction phase.

---

## Minor Pitfalls

Low severity but worth tracking to avoid accruing noise.

---

### Pitfall 11: `developerExtrasEnabled` in Production Builds

Shipping with the WebKit Inspector enabled (`developerExtrasEnabled = true`) has no performance
impact, but it exposes the full DOM to users. More practically, a user right-clicking to open the
inspector may trigger an unexpected WKWebView reload, disrupting the rendering state.

**Prevention:** Gate behind `#if DEBUG`. CONCERNS.md flags this (Security, line 59).

**Phase relevance:** Any phase — one-line fix, do it as part of the first PR.

---

### Pitfall 12: `CMARK_OPT_UNSAFE` With No Comment

Passing raw HTML from markdown to WKWebView is intentional but undocumented. A future developer
seeing this flag may "fix" it to `CMARK_OPT_SAFE`, breaking documents that embed valid raw HTML.

**Prevention:** Add a `// intentional: raw HTML pass-through for trusted local files` comment.
If the milestone ever considers sandboxing the app for Mac App Store distribution, audit this
decision — sandboxing does not neutralize XSS from local files.

**Phase relevance:** Security/compliance — but add the comment now to prevent the question from
arising during optimization PRs.

---

### Pitfall 13: `swift-cmark` Pinned to a Branch, Not a Revision

`Package.swift` specifies `branch: "gfm"`. While `Package.resolved` pins a specific commit, running
`swift package update` silently advances to the branch tip and can pull in breaking C API changes.

**Prevention:** Change `Package.swift` to `.revision("924936d")` (the current locked commit) or to a
specific tag once one is available. CONCERNS.md flags this (Dependencies at Risk, line 147).

**Phase relevance:** Before any phase that touches the build system or runs `swift package update`.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Sub-100ms launch | Measuring warm not cold; optimizing cmark (already fast) | Instruments App Launch template, cold measurement protocol |
| Sub-100ms launch | Pre-warming WKWebView adding RSS for no gain | Don't pre-warm; defer non-critical init instead |
| Large file streaming | `String(contentsOf:)` memory spike | `Data(contentsOf:options:.mappedIfSafe)` + cmark C API direct |
| N-chunk progressive rendering | Sending huge payloads through `evaluateJavaScript` | `callAsyncJavaScript` with typed args; ≤50KB chunks |
| N-chunk progressive rendering | Escaping bugs in manual JS string construction | Switch to `callAsyncJavaScript(arguments:)` for typed parameter passing |
| Memory reduction | Retain cycle via script message handler never releasing WKWebView | Weak-proxy fix must come before any RSS measurement |
| Memory reduction | Mermaid 3MB in Swift heap + WebKit process | Switch to `<script src>` tag |
| Window management | All windows opening at same position due to shared frame key | Per-file autosave key or cascade-only approach |
| Window management | Frame save "works" but isReleasedWhenClosed leaves ghost windows | Verify deallocation with deinit logging before persistence work |
| Any refactor | Swift 6 concurrency warnings flood the output | Add `@MainActor` to WebContentView before refactoring |

---

## Sources

- [WKWebView Retain Cycle via Script Message Handler (tigi44.github.io)](https://tigi44.github.io/ios/iOS,-Objective-c-WKWebView-ScriptMessageHandler-Memory-Leak/)
- [NSWindow Memory Management (lapcatsoftware.com)](https://lapcatsoftware.com/articles/working-without-a-nib-part-12.html)
- [Swift String(contentsOf:) Memory Spike (Swift Forums)](https://forums.swift.org/t/reading-large-files-fast-and-memory-efficient/37704)
- [Swift Async File Reading with DispatchIO (losingfight.com, 2024)](https://losingfight.com/blog/2024/04/22/reading-and-writing-files-in-swift-asyncawait/)
- [String Iteration Performance (Swift Forums)](https://forums.swift.org/t/confused-by-string-iteration-performance/46723)
- [WKWebView evaluateJavaScript IPC Latency (persistent.info)](https://blog.persistent.info/2015/01/wkwebview-communication-latency.html)
- [WKWebView Warm-Up Pattern (GitHub: bernikovich/WebViewWarmUper)](https://github.com/bernikovich/WebViewWarmUper)
- [Apple: Reducing Your App's Launch Time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- [Apple: callAsyncJavaScript Documentation](https://developer.apple.com/documentation/webkit/wkwebview/3656441-callasyncjavascript)
- [Premature Optimization (DEV Community)](https://dev.to/mirnes_mrkaljevic/premature-optimization-3g81)
- [Progressive Rendering via Multiple Flushes (phpied.com)](https://www.phpied.com/progressive-rendering-via-multiple-flushes/)
- [cmark-gfm Benchmarks (GitHub: swiftlang/swift-cmark)](https://github.com/swiftlang/swift-cmark/blob/gfm/benchmarks.md)
- [NSWindow isReleasedWhenClosed (optshiftk.com)](https://optshiftk.com/2011/10/26/nswindowcontroller-and-nswindow-isreleasedwhenclosed/)
- [App Launch Time Tips (SwiftLee)](https://www.avanderlee.com/optimization/launch-time-performance-optimization/)
- [Swift Executable Loading and Startup Performance on macOS (joyeecheung.github.io, 2025)](https://joyeecheung.github.io/blog/2025/01/11/executable-loading-and-startup-performance-on-macos/)
