# Phase 8: Streaming Pipeline - Pattern Map

**Mapped:** 2026-04-16
**Files analyzed:** 4 (3 modified + 1 test)
**Analogs found:** 4 / 4

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `MDViewer/MarkdownRenderer.swift` | service | streaming | `MDViewer/MarkdownRenderer.swift` (self -- existing batch render) | exact |
| `MDViewer/AppDelegate.swift` | controller | request-response | `MDViewer/AppDelegate.swift` (self -- existing `openFile`) | exact |
| `MDViewer/WebContentView.swift` | component | event-driven | `MDViewer/WebContentView.swift` (self -- existing `loadContent`) | exact |
| `MDViewerTests/MarkdownRendererTests.swift` | test | CRUD | `MDViewerTests/MarkdownRendererTests.swift` (self -- existing tests) | exact |

All files are modifications to existing code. No new files are created.

## Pattern Assignments

### `MDViewer/MarkdownRenderer.swift` (service, streaming)

**Analog:** Self -- new `renderStreaming` method modeled after existing `renderFullPage` + C callback pattern.

**Imports pattern** (lines 1-3):
```swift
import Foundation
import os
import cmark_gfm
```

**Context object pattern for C callback** (lines 145-148):
```swift
/// Context object passed through the C callback via Unmanaged pointer.
private final class ChunkedRenderContext {
    var chunks: [String] = []
    var hasMermaid: Bool = false
}
```
New `StreamingRenderContext` should follow this exact pattern, adding `firstChunkSent: Bool`, `onFirstChunk` closure, and remaining chunk accumulation.

**C callback with Unmanaged pointer** (lines 82-109):
```swift
let ctx = ChunkedRenderContext()
let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
defer { Unmanaged<ChunkedRenderContext>.fromOpaque(ctxPtr).release() }

cmark_render_html_chunked(
    root, options, cachedExtList,
    cmark_get_default_mem_allocator(),
    chunkByteLimit,
    { (data, len, isLast, hasMermaid, userdata) -> Int32 in
        guard let data = data, let userdata = userdata else { return 1 }
        let ctx = Unmanaged<ChunkedRenderContext>
            .fromOpaque(userdata).takeUnretainedValue()
        if len > 0 {
            let chunk = String(
                decoding: UnsafeBufferPointer(
                    start: UnsafeRawPointer(data)
                        .assumingMemoryBound(to: UInt8.self),
                    count: len
                ),
                as: UTF8.self
            )
            ctx.chunks.append(chunk)
        }
        if hasMermaid != 0 { ctx.hasMermaid = true }
        return 0
    },
    ctxPtr
)
```
The streaming version modifies the callback body: first invocation dispatches to main thread via `onFirstChunk` closure; subsequent invocations append to `ctx.remainingChunks`.

**Template concatenation pattern (STRM-02 target)** (lines 118-119):
```swift
let page = template.prefix + firstChunk + template.suffix
```
Replace with buffer-reuse assembly: `removeAll(keepingCapacity: true)` then append prefix/chunk/suffix bytes.

**Signpost pattern** (lines 123-135):
```swift
let spID = renderingSignposter.makeSignpostID()

let readState = renderingSignposter.beginInterval("file-read", id: spID)
// ... work ...
renderingSignposter.endInterval("file-read", readState)

let parseState = renderingSignposter.beginInterval("parse+chunk", id: spID)
// ... work ...
renderingSignposter.endInterval("parse+chunk", parseState)
```
New streaming method splits `"parse+chunk"` into `"parse-feed"`, `"stream-first-chunk"`, `"template-assemble"`, `"stream-remaining"`.

**File-read with mappedIfSafe** (lines 126-131):
```swift
guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
      let markdown = String(data: data, encoding: .utf8) else {
    renderingSignposter.endInterval("file-read", readState)
    return nil
}
```

**Extension caching at init** (lines 36-51):
```swift
private let cachedExtList: UnsafeMutablePointer<cmark_llist>?

init() {
    cmark_gfm_core_extensions_ensure_registered()
    let extNames = ["table", "strikethrough", "autolink", "tasklist"]
    var list: UnsafeMutablePointer<cmark_llist>? = nil
    for name in extNames {
        if let e = cmark_find_syntax_extension(name) {
            list = cmark_llist_append(
                cmark_get_default_mem_allocator(), list,
                UnsafeMutableRawPointer(e))
        }
    }
    self.cachedExtList = list
}
```
No changes needed to init -- streaming method reuses `cachedExtList`.

---

### `MDViewer/AppDelegate.swift` (controller, request-response)

**Analog:** Self -- `openFile` method refactored from batch to streaming callback style.

**Current openFile pattern** (lines 147-173):
```swift
private func openFile(_ url: URL) {
    guard let tmpl = template else { return }
    let paintState = appSignposter.beginInterval("open-to-paint")
    pendingFileOpens += 1

    let renderer = self.renderer
    DispatchQueue.global(qos: .userInitiated).async {
        guard let result = renderer.renderFullPage(fileURL: url, template: tmpl) else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingFileOpens -= 1
                appSignposter.endInterval("open-to-paint", paintState)
                let alert = NSAlert()
                alert.messageText = "Cannot Open File"
                alert.informativeText = "The file \(url.lastPathComponent) could not be read."
                alert.alertStyle = .warning
                alert.runModal()
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.pendingFileOpens -= 1
            self?.displayResult(result, for: url, paintState: paintState)
        }
    }
}
```
Streaming version replaces `renderFullPage` call with `renderStreaming` that takes `onFirstChunk` and `onComplete` closures. First chunk triggers window creation + `loadHTMLString`. Completion delivers remaining chunks.

**displayResult pattern** (lines 175-200):
```swift
private func displayResult(_ result: RenderResult, for url: URL, paintState: OSSignpostIntervalState) {
    let contentView = webViewPool.dequeue() ?? WebContentView(frame: .zero)
    contentView.delegate = self
    contentView.setNavigationDelegate(self)
    openToPaintStates[ObjectIdentifier(contentView)] = paintState

    let window = MarkdownWindow(fileURL: url, contentView: contentView)
    windows.append(window)

    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
    ) { [weak self] notification in
        guard let closedWindow = notification.object as? MarkdownWindow else { return }
        self?.windows.removeAll { $0 === closedWindow }
    }

    contentView.loadContent(
        page: result.page,
        remainingChunks: result.remainingChunks,
        hasMermaid: result.hasMermaid
    )
    window.makeKeyAndOrderFront(nil)
    window.alphaValue = 1.0
}
```
May need to split into `displayStreamingFirst` (creates window, loads first page) and use `setRemainingChunks` later. Or refactor to call `loadContent` with first page only, then `setRemainingChunks` on completion.

**Error handling pattern** (lines 157-165):
```swift
DispatchQueue.main.async { [weak self] in
    self?.pendingFileOpens -= 1
    appSignposter.endInterval("open-to-paint", paintState)
    let alert = NSAlert()
    alert.messageText = "Cannot Open File"
    alert.informativeText = "The file \(url.lastPathComponent) could not be read."
    alert.alertStyle = .warning
    alert.runModal()
}
```

**Weak self capture in closures** (lines 168-171):
```swift
DispatchQueue.main.async { [weak self] in
    self?.pendingFileOpens -= 1
    self?.displayResult(result, for: url, paintState: paintState)
}
```

---

### `MDViewer/WebContentView.swift` (component, event-driven)

**Analog:** Self -- adding `setRemainingChunks` method alongside existing `loadContent`.

**Current loadContent API** (lines 72-78):
```swift
func loadContent(page: String, remainingChunks: [String], hasMermaid: Bool) {
    self.remainingChunks = remainingChunks
    self.hasMermaid = hasMermaid
    self.hasProcessedFirstPaint = false
    let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    webView.loadHTMLString(page, baseURL: resourceURL)
}
```
New `setRemainingChunks(_:hasMermaid:)` method allows chunks to arrive after `loadContent`. If `hasProcessedFirstPaint` is already true, inject immediately; otherwise store for later injection by `firstPaint` handler.

**firstPaint handler and chunk injection gate** (lines 87-96):
```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
This is the critical gate. The streaming path must ensure remaining chunks are stored before or after this fires. If chunks arrive late (after firstPaint), `setRemainingChunks` should call `injectRemainingChunks()` directly.

**Chunk injection with staggered dispatch** (lines 121-153):
```swift
private func injectRemainingChunks() {
    guard !remainingChunks.isEmpty else { return }

    let chunkInjectState = renderingSignposter.beginInterval("chunk-inject")
    let chunks = remainingChunks
    let chunkCount = chunks.count
    remainingChunks = []

    for (index, chunk) in chunks.enumerated() {
        let delay = Double(index) * 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                if index == chunkCount - 1 {
                    renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                }
                return
            }
            self.webView.callAsyncJavaScript(
                "window.appendChunk(html)",
                arguments: ["html": chunk],
                in: nil,
                in: .page,
                completionHandler: { _ in
                    if index == chunkCount - 1 {
                        renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                    }
                }
            )
        }
    }
}
```

**Property declaration pattern** (lines 37-40):
```swift
private var remainingChunks: [String] = []
private var hasMermaid = false
private var isMonospace = false
private var hasProcessedFirstPaint = false
```

---

### `MDViewerTests/MarkdownRendererTests.swift` (test)

**Analog:** Self -- add tests for streaming render method.

**Test structure pattern** (lines 4-8):
```swift
final class MarkdownRendererTests: XCTestCase {

    func testBasicMarkdownRendersToHTML() {
        let renderer = MarkdownRenderer()
        let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
```

**Full page render test** (lines 74-80):
```swift
func testFullPageHTML() {
    let renderer = MarkdownRenderer()
    let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
    let result = renderer.renderFullPage(markdown: "# Test", template: template)
    XCTAssertTrue(result.page.contains("<h1>"))
    XCTAssertTrue(result.page.contains("<body>"))
}
```
New streaming tests should follow this pattern: create renderer + template, call `renderStreaming`, use `XCTestExpectation` for async callback verification.

**Large content chunking test** (lines 50-66):
```swift
func testChunkingSplitsLargeContent() {
    let renderer = MarkdownRenderer()
    var md = ""
    for i in 0..<500 {
        md += "## Heading \(i)\n\n" + String(repeating: "Word ", count: 60) + "\n\n"
    }
    let (chunks, _) = renderer.render(markdown: md)
    XCTAssertGreaterThan(chunks.count, 2, "Content well over 64KB should produce more than 2 chunks")
}
```

**Temp file test pattern** (lines 88-98):
```swift
func testRenderFromFile() {
    let renderer = MarkdownRenderer()
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.md")
    try! "# File Test\n\nContent".write(to: tmpFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
    let result = renderer.renderFullPage(fileURL: tmpFile, template: template)
    XCTAssertNotNil(result)
    XCTAssertTrue(result!.page.contains("File Test"))
}
```

---

## Shared Patterns

### OSSignposter Instrumentation
**Source:** `MDViewer/MarkdownRenderer.swift` lines 28-31, `MDViewer/AppDelegate.swift` lines 6-9
**Apply to:** All modified files (MarkdownRenderer, AppDelegate)
```swift
let renderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)

// Usage:
let spID = renderingSignposter.makeSignpostID()
let state = renderingSignposter.beginInterval("interval-name", id: spID)
// ... work ...
renderingSignposter.endInterval("interval-name", state)
```

### Unmanaged Pointer for C Callback Context
**Source:** `MDViewer/MarkdownRenderer.swift` lines 82-84
**Apply to:** New `StreamingRenderContext` class
```swift
let ctx = ChunkedRenderContext()
let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
defer { Unmanaged<ChunkedRenderContext>.fromOpaque(ctxPtr).release() }
```
Pattern: `passRetained` to create, `takeUnretainedValue` inside callback, `release` in `defer` after callback loop completes.

### Weak Self in Dispatch Closures
**Source:** `MDViewer/AppDelegate.swift` lines 168-171
**Apply to:** All `DispatchQueue.main.async` blocks in streaming callbacks
```swift
DispatchQueue.main.async { [weak self] in
    self?.pendingFileOpens -= 1
    self?.displayResult(result, for: url, paintState: paintState)
}
```

### Guard-Return Error Handling
**Source:** `MDViewer/MarkdownRenderer.swift` lines 126-131
**Apply to:** File read in streaming render method
```swift
guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
      let markdown = String(data: data, encoding: .utf8) else {
    return nil  // or call error callback
}
```

### Class-Level Final + Private Properties
**Source:** `MDViewer/MarkdownRenderer.swift` line 33-34
**Apply to:** New buffer properties on MarkdownRenderer
```swift
final class MarkdownRenderer {
    private let chunkByteLimit = 64 * 1024
```
New buffer properties (`assemblyBuffer`, `prefixBytes`, `suffixBytes`) follow the same `private` access pattern.

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| (none) | -- | -- | All changes are to existing files with clear self-analogs |

## Metadata

**Analog search scope:** `MDViewer/`, `MDViewerTests/`
**Files scanned:** 7 (4 source + 3 test)
**Pattern extraction date:** 2026-04-16
