# Phase 9: Native Text Rendering - Pattern Map

**Mapped:** 2026-04-16
**Files analyzed:** 7 (2 new, 5 modified)
**Analogs found:** 7 / 7

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `MDViewer/NativeRenderer.swift` | service | transform | `MDViewer/MarkdownRenderer.swift` | exact |
| `MDViewer/NativeContentView.swift` | component | request-response | `MDViewer/WebContentView.swift` | exact |
| `MDViewer/MarkdownRenderer.swift` | service | transform | (self - adding AST pre-scan) | self-modify |
| `MDViewer/MarkdownWindow.swift` | component | request-response | (self - generalize content view type) | self-modify |
| `MDViewer/AppDelegate.swift` | controller | request-response | (self - routing + font reg + menu) | self-modify |
| `MDViewer/Resources/fonts/*.otf` | config | file-I/O | `MDViewer/Resources/fonts/*.woff2` | role-match |
| `MDViewerTests/NativeRendererTests.swift` | test | transform | `MDViewerTests/MarkdownRendererTests.swift` | exact |

## Pattern Assignments

### `MDViewer/NativeRenderer.swift` (service, transform) -- NEW

**Analog:** `MDViewer/MarkdownRenderer.swift`

**Imports pattern** (lines 1-3):
```swift
import Foundation
import os
import cmark_gfm
```

**Class declaration pattern** (line 33):
```swift
final class MarkdownRenderer {
```
Convention: `final class`, no protocol conformance for pure data transformation classes.

**cmark C API usage pattern** (lines 60-79):
```swift
let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE

guard let parser = cmark_parser_new(options) else {
    return (["<p>Failed to create parser.</p>"], false)
}
defer { cmark_parser_free(parser) }

// Attach extensions to parser
let extNames = ["table", "strikethrough", "autolink", "tasklist"]
for name in extNames {
    if let e = cmark_find_syntax_extension(name) {
        cmark_parser_attach_syntax_extension(parser, e)
    }
}

cmark_parser_feed(parser, markdown, markdown.utf8.count)
guard let root = cmark_parser_finish(parser) else {
    return (["<p>Failed to parse markdown.</p>"], false)
}
defer { cmark_node_free(root) }
```
Key: Always `defer` free for C resources. Use `guard let` + early return for parser/root failures.

**Return type pattern** (lines 5-9):
```swift
struct RenderResult {
    let page: String
    let remainingChunks: [String]
    let hasMermaid: Bool
}
```
Convention: Immutable value type with `let` fields for render output. NativeRenderer should define an equivalent (e.g., `NativeRenderResult` with `attributedString: NSAttributedString`).

**OSSignposter pattern** (lines 28-31):
```swift
let renderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
```
Convention: Module-level signposter constant, reused across the file. Use `beginInterval`/`endInterval` pairs.

---

### `MDViewer/NativeContentView.swift` (component, request-response) -- NEW

**Analog:** `MDViewer/WebContentView.swift`

**Imports pattern** (lines 1-3):
```swift
import Cocoa
import os
import WebKit
```
NativeContentView replaces `WebKit` with no additional import (AppKit NSTextView is in Cocoa).

**Delegate protocol pattern** (lines 5-7):
```swift
protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}
```
Convention: `AnyObject`-constrained protocol. Single method. NativeContentView needs an equivalent delegate callback (or reuse same protocol with a common base).

**Class declaration + properties pattern** (lines 9, 34-40):
```swift
final class WebContentView: NSView, WKScriptMessageHandler {
    weak var delegate: WebContentViewDelegate?
    private let webView: WKWebView
    private var remainingChunks: [String] = []
    private var hasMermaid = false
    private var isMonospace = false
}
```
Convention: `final class`, NSView subclass, `weak var delegate`, private stored properties with inline defaults.

**Init pattern** (lines 42-65):
```swift
override init(frame: NSRect) {
    // Configure child views before super.init
    webView = WKWebView(frame: .zero, configuration: config)

    super.init(frame: frame)

    // Add subview and constraints after super.init
    webView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(webView)

    NSLayoutConstraint.activate([
        webView.topAnchor.constraint(equalTo: topAnchor),
        webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        webView.leadingAnchor.constraint(equalTo: leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
}

required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
}
```
Convention: Initialize child views before `super.init`. Auto Layout with `translatesAutoresizingMaskIntoConstraints = false`. `fatalError` for `init(coder:)`.

**Content loading pattern** (lines 72-78):
```swift
func loadContent(page: String, remainingChunks: [String], hasMermaid: Bool) {
    self.remainingChunks = remainingChunks
    self.hasMermaid = hasMermaid
    self.hasProcessedFirstPaint = false
    let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    webView.loadHTMLString(page, baseURL: resourceURL)
}
```
NativeContentView equivalent: `func loadContent(attributedString: NSAttributedString)` -- set textStorage, fire delegate immediately (no async paint signal needed).

**Deinit debug pattern** (lines 129-134):
```swift
deinit {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")
    #if DEBUG
    print("[WebContentView] deinit - \(ObjectIdentifier(self))")
    #endif
}
```
Convention: Cleanup in deinit, `#if DEBUG` print with class name and ObjectIdentifier.

---

### `MDViewer/MarkdownRenderer.swift` (service, transform) -- MODIFY

**Modification:** Add `canRenderNatively(root:)` method and expose parsed AST root for native path.

**Extension attachment pattern to reuse** (lines 36-51):
```swift
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
The pre-scan method follows the same cmark C API conventions: `guard let`, `defer` for free, string comparison via `cmark_node_get_type_string`.

---

### `MDViewer/MarkdownWindow.swift` (component, request-response) -- MODIFY

**Current tight coupling** (lines 8-10):
```swift
let contentViewWrapper: WebContentView

init(fileURL: URL, contentView: WebContentView) {
    self.contentViewWrapper = contentView
```
**Required change:** Generalize `contentViewWrapper` type. Options:
1. Protocol-based: Define `ContentViewProtocol` conforming types swap in/out
2. NSView-based: Store as `NSView` with type-checked access methods

**Window configuration pattern to preserve** (lines 27-50):
```swift
super.init(
    contentRect: centeredFrame,
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered,
    defer: false
)

self.contentView = contentView
self.title = fileURL.lastPathComponent
self.titlebarAppearsTransparent = false
self.isReleasedWhenClosed = false
self.minSize = NSSize(width: 400, height: 300)
self.alphaValue = 0
```

**Fade-in pattern** (lines 60-65):
```swift
func showWithFadeIn() {
    makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        self.animator().alphaValue = 1.0
    }
}
```
This must work identically for both native and web content views.

---

### `MDViewer/AppDelegate.swift` (controller, request-response) -- MODIFY

**Routing decision point** -- `openFile(_:)` method (lines 147-211):
The render path routing happens here. Currently always creates WebContentView. Must add:
1. Parse markdown (reuse existing cmark setup)
2. Call `canRenderNatively(root:)` pre-scan
3. Branch to NativeRenderer + NativeContentView or existing WebContentView path

**Font registration insertion point** -- `applicationDidFinishLaunching` (lines 23-44):
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    loadTemplate()
    setupMenu()
    // INSERT: registerBundledFonts() call here
    NSApp.activate(ignoringOtherApps: true)
```

**Menu setup pattern** (lines 240-269):
```swift
let viewMenuItem = NSMenuItem()
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(withTitle: "Toggle Monospace", action: #selector(toggleMonospace(_:)), keyEquivalent: "m")
viewMenuItem.submenu = viewMenu
mainMenu.addItem(viewMenuItem)
```
Add "Toggle Native/Web Rendering" menu item following same pattern.

**Menu action pattern** (lines 99-101):
```swift
@objc func toggleMonospace(_ sender: Any?) {
    guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
    window.contentViewWrapper.toggleMonospace()
}
```
Convention: `@objc`, `guard let window = NSApp.keyWindow as? MarkdownWindow`, delegate to content view.

**Window lifecycle pattern** (lines 173-183):
```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification,
    object: window,
    queue: .main
) { [weak self] notification in
    guard let closedWindow = notification.object as? MarkdownWindow else { return }
    self?.windows.removeAll { $0 === closedWindow }
}
```

**Error alert pattern** (lines 200-207):
```swift
let alert = NSAlert()
alert.messageText = "Cannot Open File"
alert.informativeText = "The file \(url.lastPathComponent) could not be read."
alert.alertStyle = .warning
alert.runModal()
```

---

### `MDViewerTests/NativeRendererTests.swift` (test, transform) -- NEW

**Analog:** `MDViewerTests/MarkdownRendererTests.swift`

**Test file structure** (lines 1-4):
```swift
import XCTest
@testable import MDViewer

final class MarkdownRendererTests: XCTestCase {
```

**Basic render test pattern** (lines 6-13):
```swift
func testBasicMarkdownRendersToHTML() {
    let renderer = MarkdownRenderer()
    let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
    let joined = chunks.joined()
    XCTAssertTrue(joined.contains("<h1>"))
    XCTAssertTrue(joined.contains("Hello"))
}
```
NativeRenderer equivalent: create renderer, render markdown string, assert attributed string contains expected text and attributes.

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
}
```

**Naming convention:** Test methods named `test<Feature><Scenario>` (e.g., `testBasicMarkdownRendersToHTML`, `testMermaidBlockBecomesPlaceholder`).

---

## Shared Patterns

### Memory Management (C Resources)
**Source:** `MDViewer/MarkdownRenderer.swift` lines 62-79
**Apply to:** `NativeRenderer.swift`, any code touching cmark AST
```swift
guard let parser = cmark_parser_new(options) else { return /* fallback */ }
defer { cmark_parser_free(parser) }
// ...
guard let root = cmark_parser_finish(parser) else { return /* fallback */ }
defer { cmark_node_free(root) }
```

### NSView Init Convention
**Source:** `MDViewer/WebContentView.swift` lines 42-70
**Apply to:** `NativeContentView.swift`
```swift
override init(frame: NSRect) {
    // Initialize stored properties
    super.init(frame: frame)
    // Configure subviews with Auto Layout
}
required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
}
```

### Delegate Pattern
**Source:** `MDViewer/WebContentView.swift` lines 5-7, 34
**Apply to:** `NativeContentView.swift` (either reuse WebContentViewDelegate via protocol rename, or create NativeContentViewDelegate)
```swift
protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}
// ...
weak var delegate: WebContentViewDelegate?
```

### Debug Logging
**Source:** `MDViewer/WebContentView.swift` lines 131-133, `MDViewer/MarkdownWindow.swift` lines 55-58
**Apply to:** `NativeContentView.swift`, `NativeRenderer.swift`
```swift
deinit {
    #if DEBUG
    print("[ClassName] deinit - \(ObjectIdentifier(self))")
    #endif
}
```

### OSSignposter Instrumentation
**Source:** `MDViewer/MarkdownRenderer.swift` lines 28-31, `MDViewer/AppDelegate.swift` lines 6-9
**Apply to:** `NativeRenderer.swift` render method
```swift
let renderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
// Usage:
let spID = renderingSignposter.makeSignpostID()
let state = renderingSignposter.beginInterval("native-render", id: spID)
// ... work ...
renderingSignposter.endInterval("native-render", state)
```

### Class Design
**Source:** All Swift files
**Apply to:** All new files
- `final class` for concrete types not designed for subclassing
- `private` for all implementation details
- `[weak self]` in all closures capturing self
- Boolean properties: `is`/`has` prefix (`isMonospace`, `hasMermaid`)
- Static constants: camelCase, scoped to owning type

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `MDViewer/Resources/fonts/*.otf` | config | file-I/O | OTF font files are new binary assets; WOFF2 analogs exist but format differs. Acquire from CTAN Latin Modern package. |

## Metadata

**Analog search scope:** `MDViewer/`, `MDViewerTests/`
**Files scanned:** 9 Swift source files + 3 test files
**Pattern extraction date:** 2026-04-16
