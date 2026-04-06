# Technology Stack: Performance Optimization

**Project:** MDViewer — macOS AppKit + WKWebView markdown viewer
**Researched:** 2026-04-03
**Scope:** Speed and memory optimization milestone

## Summary

MDViewer's existing stack (AppKit + WKWebView + cmark-gfm, Swift 5.9, macOS 13+) is correct. No
stack replacements are needed. This document prescribes which specific APIs, profiling tools, and
techniques to apply within that stack to hit sub-100ms launch, stream large files, and reduce
per-window memory.

---

## Profiling Tools (Use These First)

### Instruments: App Launch Template

**What it is:** Xcode built-in. Profile via `Cmd+I` in Xcode, select the "App Launch" template.

**Why:** Measures pre-main time (dylib loading, ObjC runtime setup, static initializers) AND
post-main time (applicationDidFinishLaunching, first content paint) in a single trace.

**Use over `DYLD_PRINT_STATISTICS`:** `DYLD_PRINT_STATISTICS` only measures pre-main. The App
Launch template covers the full lifecycle including Swift/ObjC initialization and custom code.
It also integrates `os_signpost` markers, making it the authoritative tool for this milestone.

**Do not use:** Simulator. Instruments results on Simulator deviate 30%+ from real hardware.
Always profile on the target Mac.

### Instruments: Time Profiler

**What it is:** Xcode built-in. Samples the call stack at 1ms intervals.

**Why:** Identifies hot functions in `MarkdownRenderer.renderFullPage` and the JS injection loop.
Use in combination with App Launch for post-paint performance work.

### Instruments: Allocations + VM Tracker

**What they are:** Xcode built-in. Allocations tracks live heap objects; VM Tracker shows virtual
memory committed per category (including WebKit's process-isolated memory).

**Why:** Per-window memory footprint reduction requires measuring WKWebView process memory
separately from Swift heap. VM Tracker exposes this. Allocations catches retained strings from
large file reads that should be freed after the first HTML chunk is delivered to the view.

### os_signpost (OSSignposter API)

**What it is:** Apple system framework, zero-overhead when disabled. Available macOS 12+.

**Why:** Adds named time intervals that appear in Instruments traces. Essential for measuring the
pipeline stages this project owns: file read, cmark parse, HTML string construction, template
assembly, WKWebView load, firstPaint callback.

**How to use:**

```swift
import os

private let signposter = OSSignposter(subsystem: "com.mdviewer.app", category: "Rendering")

// In MarkdownRenderer.renderFullPage:
let state = signposter.beginInterval("parseMarkdown")
// ... cmark_parse_document call ...
signposter.endInterval("parseMarkdown", state)
```

Wrap each pipeline phase. View results in Instruments > Points of Interest.

**Do not use:** `print()` or `NSLog()` for timing — they pollute the main thread and distort
measurements. Use `os_signpost` exclusively.

---

## File I/O: Streaming Large Files

### Recommended API: `Data(contentsOf:options:.mappedIfSafe)`

**What it is:** Foundation built-in. Maps the file into virtual memory via `mmap` rather than
copying all bytes into the process heap.

**Why:** For read-only access (which MDViewer always is), `.mappedIfSafe` means pages are only
faulted in as cmark reads through them. For a 10MB markdown file, the OS may never load all
pages into physical RAM. Peak heap usage stays near zero for the file content itself.

**Caveat:** `.mappedIfSafe` will fall back to a full copy for files on external or network
volumes. This is acceptable — the fallback is no worse than the current `Data(contentsOf:)`
call.

**Replaces:** The current `String(contentsOf:)` path (if it exists) or bare `Data(contentsOf:)`
without the mapping option.

**Do not use:**
- `String(contentsOf:)` for large files — loads the entire file as a Swift String, tripling
  memory use (Data → bytes → UTF-16 String).
- `FileHandle.bytes.lines` — correct for line-by-line streaming but wrong here because cmark-gfm
  requires the entire document to build the AST. Line-streaming forces re-assembly anyway.
- `InputStream` chunked reading — same problem: cmark cannot parse partial markdown into correct
  HTML without the full document context.

**Implementation pattern:**

```swift
let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
// Pass directly to cmark via withUnsafeBytes — no String conversion
data.withUnsafeBytes { ptr in
    cmark_parse_document(ptr.baseAddress, data.count, options)
}
```

### cmark-gfm Streaming API: `cmark_parser_feed` / `cmark_parser_finish`

**What it is:** The incremental parser API exposed by `cmark-gfm` (confirmed in `cmark-gfm.h`).

**APIs:**
- `cmark_parser_new(options)` — allocate parser
- `cmark_parser_feed(parser, buffer, len)` — feed a chunk of bytes
- `cmark_parser_finish(parser)` — complete parse, return AST root node
- `cmark_iter_new(root)` / `cmark_iter_next(iter)` — traverse AST node by node

**Why this matters for N-chunk progressive rendering:** The current code calls
`cmark_parse_document` (one-shot) and then splits the resulting HTML string. Instead:

1. Feed the entire file via `cmark_parser_feed` (one call with the mapped Data buffer — no
   incremental I/O benefit since cmark needs full input, but the API is the right one for future
   streaming if file I/O is split).
2. After `cmark_parser_finish`, traverse the AST with `cmark_iter`. Emit HTML nodes into chunks
   by block-level element count rather than byte offset on the HTML string. This gives N natural
   HTML chunks (each complete block element) without post-hoc string splitting.

**Do not use:** Custom regex/string splitting on the rendered HTML output. The current
`{{FIRST_CHUNK}}` split is fragile for large files. AST-level chunking is cleaner and enables
true N-chunk delivery.

### AST Traversal for N-Chunk Rendering

**APIs (confirmed in `cmark-gfm.h`):**
- `cmark_iter_get_node(iter)` — current AST node
- `cmark_iter_get_event_type(iter)` — `CMARK_EVENT_ENTER` / `CMARK_EVENT_EXIT` / `CMARK_EVENT_DONE`
- `cmark_node_render_html(node, options, extensions)` — render a single node to HTML

**Pattern:** Walk top-level children of the document node. Accumulate N nodes per chunk. Render
each chunk to HTML separately. This replaces the current byte-count split with a semantically
correct HTML chunk that always ends on a block boundary.

---

## WKWebView Memory Management

### WKProcessPool: Do Not Manage Manually

**Status:** On macOS 12+, WKWebView instances automatically share a single web content process
(the `WKProcessPool` API is effectively a no-op when not explicitly configured). The
`PROJECT.md` already notes this. Do not add any WKProcessPool code.

**Why it matters for multiple windows:** Each `MarkdownWindow` gets a separate `WKWebView`. On
macOS 13+, these run in a shared process by default, so the per-window memory overhead is
primarily the DOM/heap of each document, not a full OS process per window.

### WKWebView Pre-Warming

**What it is:** Allocating a `WKWebView` before it is needed so the first display is instant.

**Why:** WKWebView initialization allocates the web content process and sets up IPC channels.
This takes 80-150ms on first use. Pre-warming during `applicationDidFinishLaunching` (before the
first file open) amortizes this cost.

**Implementation pattern:**

```swift
// In AppDelegate.applicationDidFinishLaunching — after existing setup
private var warmupWebView: WKWebView?

func prewarmWebView() {
    // Allocate on main thread; holds process channels open
    let config = WKWebViewConfiguration()
    warmupWebView = WKWebView(frame: .zero, configuration: config)
    // Load a trivial blank page to fully initialize the process
    warmupWebView?.loadHTMLString("<html></html>", baseURL: nil)
}
```

Discard `warmupWebView` after the first real `WebContentView` is created, or reuse its
configuration. Do not keep it alive indefinitely.

**Do not use:** Third-party warmup libraries (WebViewWarmUper, WKWebView_WarmUp) — they target
iOS UIKit and add unnecessary SPM complexity. The pattern above is five lines of native code.

### WKWebView Memory After Close

**Issue:** WKWebView retains significant memory after its window closes. The existing code
removes the window from `AppDelegate.windows` via `NSWindow.willCloseNotification` but may not
nil the WKWebView reference inside `WebContentView`.

**Fix:** In `WebContentView` cleanup, call `webView.loadHTMLString("", baseURL: nil)` before
releasing the reference. This signals the web content process to drop the DOM and GC the heap
before the process is truly idle.

```swift
func prepareForReuse() {
    webView.loadHTMLString("", baseURL: nil)
}
```

Call from `MarkdownWindow`'s `willClose` observer.

### JavaScript Injection: `callAsyncJavaScript` over `evaluateJavaScript`

**What it is:** `WKWebView.callAsyncJavaScript(_:arguments:in:in:completionHandler:)` —
available macOS 11+. Passes arguments as a typed Swift dictionary rather than embedding them in
the JS string.

**Why to prefer for chunk injection:**

1. Arguments are serialized by WebKit's IPC layer (structured clone), not Swift string
   concatenation. This avoids the `"window.appendChunk('\(html)')"` pattern which will crash on
   HTML containing single quotes or backslashes.
2. Avoids a separate JS string escaping pass.
3. Native async/await support (use the `async` overload on macOS 11+).

**Use for:**

```swift
// Replace: webView.evaluateJavaScript("window.appendChunk('\(escapedHTML)')")
// With:
webView.callAsyncJavaScript(
    "window.appendChunk(html)",
    arguments: ["html": chunkHTML],
    in: nil,
    in: .defaultClient
) { _ in }
```

**Keep `evaluateJavaScript` for:** Side-effect-only calls with no arguments
(`window.toggleMonospace()`, `window.initMermaid()`).

---

## Launch Time: Pre-Main Reduction

### Reduce Dynamic Frameworks

**Current state:** The app links `swift-cmark` as a dynamic library via SPM. Each dynamic
library adds dyld load time.

**Recommendation:** If `swift-cmark` supports static linking (confirm in `project.yml`), switch
to static. The "App Launch" instrument will show dyld time separately from main-thread time.

**Target:** Apple's guidance is fewer than 6 non-system dynamic frameworks. MDViewer should have
zero third-party dynamic frameworks.

**How to verify:** Run the App Launch instrument. The "dyld" phase bar should be under 20ms.

### Move Template Loading Off Critical Path

**Current state:** `ensureTemplateLoaded()` reads and splits `template.html` synchronously
during `applicationDidFinishLaunching`. This is correct architecture but blocks main thread.

**Recommendation:** Measure with `os_signpost` first. If template loading exceeds 5ms, move
the file read to a `DispatchQueue.global` dispatch in `main.swift` before
`NSApplicationMain()`. Cache the result in a global `let` (thread-safe lazy initialization).

### Static Initializers

**What to check:** Any `+load` equivalent in Swift (global `var` with complex initializers,
`@_silgen_name`, or ObjC bridging classes). The App Launch instrument's pre-main section
surfaces these.

**Swift `static let` is safe:** Swift module-level `static let` constants are lazily initialized
on first access using OS-level `dispatch_once`. They do NOT run at pre-main time.

**Avoid:** Global `var` with non-trivial initializers that run unconditionally before `main()`.

---

## Window Position Persistence

### Recommended API: `NSWindow.setFrameAutosaveName`

**What it is:** AppKit built-in. Reads/writes window frame to `NSUserDefaults` automatically.

**Why:** Zero custom code. AppKit handles multi-screen, multi-window, and
Spaces-awareness automatically.

**Implementation:**

```swift
// In MarkdownWindow.init (after setting the frame):
setFrameAutosaveName("MDViewer-\(fileURL.lastPathComponent)")
```

Using the filename as the autosave name means each file remembers its own position. Use a
fixed name like `"MDViewer-Main"` if position should be shared across all windows.

**Do not use:** `NSUserDefaults` manual frame serialization — it duplicates what
`setFrameAutosaveName` already does and adds persistence bugs (stale positions on external
monitors).

---

## Swift Concurrency: Keep DispatchQueue for This Milestone

**Recommendation:** Do NOT migrate rendering pipeline to Swift async/await in this milestone.

**Rationale:** The current `DispatchQueue.global(qos: .userInitiated)` dispatch in
`AppDelegate.openFile` is correct, well-understood, and has no known performance penalty vs.
Swift concurrency for this use case. Migrating to `async/await` and `Task` requires a Swift 6
concurrency audit of the entire delegate chain and WKWebView interaction. That is a separate
milestone, not a performance optimization.

**Exception:** `callAsyncJavaScript` uses `async/await` — apply only to that call site, wrapped
in a non-isolated context.

---

## Alternatives Considered and Rejected

| Category | Rejected Option | Why Rejected |
|----------|----------------|--------------|
| Markdown parser | Replace cmark-gfm with Swift-native parser | cmark-gfm is already <10ms for large files. Replacement risk exceeds gain. |
| Rendering | Replace WKWebView with NSTextView / TextKit 2 | Cannot render Mermaid diagrams. Typography fidelity requires CSS. |
| File I/O | Line-by-line streaming via `FileHandle.bytes.lines` | cmark requires full document; streaming lines forces re-assembly before parse. |
| File I/O | `DispatchIO` chunked read | Same problem: partial reads cannot be fed to cmark incrementally without document-level context. |
| Concurrency | Swift async/await full migration | Scope creep; WKWebView main-actor requirements complicate the migration path. |
| JS injection | `evaluateJavaScript` with string escaping | Unsafe for arbitrary HTML (quote injection). `callAsyncJavaScript` with arguments is the correct replacement. |
| Warmup | Third-party WKWebView warmup libraries | Unnecessary dependency; native pattern is equivalent. |

---

## Sources

- cmark-gfm header API reference (confirmed): https://github.com/github/cmark-gfm/blob/master/src/cmark-gfm.h
- swift-cmark (apple fork, gfm branch): https://github.com/swiftlang/swift-cmark/blob/gfm/README.md
- WKWebView memory guidance: https://embrace.io/blog/wkwebview-memory-leaks/
- callAsyncJavaScript API: https://developer.apple.com/documentation/webkit/wkwebview/3656441-callasyncjavascript
- Large file reading in Swift async/await (2024): https://losingfight.com/blog/2024/04/22/reading-and-writing-files-in-swift-asyncawait/
- Swift globals and static lazy init: https://www.jessesquires.com/blog/2020/07/16/swift-globals-and-static-members-are-atomic-and-lazily-computed/
- Slow app startup times (dylib analysis): https://useyourloaf.com/blog/slow-app-startup-times/
- os_signpost for performance measurement: https://www.polpiella.dev/time-profiler-instruments/
- FileHandle.bytes memory efficiency: https://forums.swift.org/t/reading-large-files-fast-and-memory-efficient/37704
- NSWindow frame autosave: https://dev.to/onmyway133/how-to-save-window-size-and-position-in-macos-3e5n
- mappedIfSafe documentation: https://developer.apple.com/documentation/foundation/nsdata/readingoptions/mappedifsafe

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Profiling tools (Instruments, os_signpost) | HIGH | Apple official tools, stable across Xcode versions |
| cmark-gfm streaming API (`cmark_parser_feed`, AST iter) | HIGH | Verified directly from `cmark-gfm.h` header |
| `Data(contentsOf:options:.mappedIfSafe)` | HIGH | Apple official API, documented behavior |
| WKWebView pre-warming technique | MEDIUM | Pattern confirmed from multiple iOS/macOS sources; exact timing savings on macOS 13+ not benchmarked |
| `callAsyncJavaScript` for chunk injection | HIGH | Apple official API, macOS 11+, stable |
| `setFrameAutosaveName` for window position | HIGH | Standard AppKit API, documented |
| Dynamic vs static linking impact | MEDIUM | Principle confirmed; actual saving depends on swift-cmark SPM configuration |
| Swift async/await migration deferral | HIGH | Correct decision given WKWebView main-actor constraints |
