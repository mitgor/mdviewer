# Architecture

**Analysis Date:** 2026-04-03

## Pattern Overview

**Overall:** Single-delegate AppKit application with a three-phase progressive rendering pipeline.

**Key Characteristics:**
- No view model layer — `AppDelegate` owns all coordination logic between file I/O, rendering, and windowing
- Rendering is offloaded to a background thread; all UI mutations happen on the main thread
- WKWebView is used as the rendering surface; Swift ↔ JavaScript communication is bidirectional via `WKScriptMessageHandler` and `evaluateJavaScript`
- Content is split into chunks at render time to keep initial paint fast; remaining content is injected asynchronously after the first paint signal

## Layers

**Application Layer:**
- Purpose: App lifecycle, menu construction, file open coordination, window management
- Location: `MDViewer/AppDelegate.swift`
- Contains: `NSApplicationDelegate`, `WebContentViewDelegate` conformances, window array, template loading
- Depends on: `MarkdownRenderer`, `MarkdownWindow`, `WebContentView`, `SplitTemplate`, `RenderResult`
- Used by: macOS (entry point via `MDViewer/main.swift`)

**Rendering Layer:**
- Purpose: Parse markdown to HTML using cmark-gfm, detect and transform Mermaid blocks, split output into progressive chunks
- Location: `MDViewer/MarkdownRenderer.swift`
- Contains: `MarkdownRenderer` class, `RenderResult` struct, `SplitTemplate` struct
- Depends on: `cmark_gfm`, `cmark_gfm_extensions` (C libraries via Swift Package)
- Used by: `AppDelegate.openFile(_:)` on a background `DispatchQueue`

**View Layer:**
- Purpose: Host and control the WKWebView, manage progressive content injection, handle JS ↔ native messaging
- Location: `MDViewer/WebContentView.swift`
- Contains: `WebContentView` (NSView subclass), `WebContentViewDelegate` protocol
- Depends on: WebKit, `WKWebView`, `WKScriptMessageHandler`
- Used by: `AppDelegate.displayResult(_:for:)`

**Window Layer:**
- Purpose: Wrap WebContentView in a styled NSWindow with fade-in animation and ProMotion configuration
- Location: `MDViewer/MarkdownWindow.swift`
- Contains: `MarkdownWindow` (NSWindow subclass)
- Depends on: Cocoa, QuartzCore
- Used by: `AppDelegate.displayResult(_:for:)`

**Template/Static Assets:**
- Purpose: HTML shell with embedded CSS, JavaScript progressive loading logic, and Mermaid initialization
- Location: `MDViewer/Resources/template.html`, `MDViewer/Resources/mermaid.min.js`, `MDViewer/Resources/fonts/`
- Contains: Full page HTML, all styling, `appendChunk`, `initMermaid`, `toggleMonospace` JS functions
- Used by: `SplitTemplate` (split at `{{FIRST_CHUNK}}` marker at load time), `WebContentView.loadAndInitMermaid()`

## Data Flow

**File Open Flow:**

1. `AppDelegate` receives file URL (via Finder drag-drop, `application(_:open:)`, CLI argument, or `NSOpenPanel`)
2. `AppDelegate.openFile(_:)` dispatches to `DispatchQueue.global(qos: .userInitiated)`
3. `MarkdownRenderer.renderFullPage(fileURL:template:)` reads file, parses markdown to HTML via cmark-gfm, processes Mermaid blocks, and chunks the output into `RenderResult`
4. Back on main thread, `AppDelegate.displayResult(_:for:)` creates `WebContentView` and `MarkdownWindow`
5. `WebContentView.loadContent(page:remainingChunks:hasMermaid:)` calls `webView.loadHTMLString(_:baseURL:)` with the first chunk already inlined into the template
6. WKWebView fires `DOMContentLoaded`; the JS handler posts `window.webkit.messageHandlers.firstPaint.postMessage('ready')`
7. `WebContentView.userContentController(_:didReceive:)` receives `"firstPaint"`, notifies delegate (triggering fade-in), then calls `injectRemainingChunks()` and optionally `loadAndInitMermaid()`
8. `injectRemainingChunks()` calls `window.appendChunk(html)` via `evaluateJavaScript` with 16ms staggering between chunks
9. If Mermaid is needed, `loadAndInitMermaid()` injects `mermaid.min.js` then calls `window.initMermaid()`; diagrams render sequentially via `requestAnimationFrame`

**Monospace Toggle Flow:**

1. `AppDelegate.toggleMonospace(_:)` resolves the key window as `MarkdownWindow`
2. Calls `window.contentViewWrapper.toggleMonospace()`
3. `WebContentView.toggleMonospace()` calls `webView.evaluateJavaScript("window.toggleMonospace()")`
4. JS toggles `document.body.classList.toggle('monospace')`

**State Management:**
- `AppDelegate` holds an array of open `MarkdownWindow` instances (`windows: [MarkdownWindow]`)
- Windows are removed from the array via `NSWindow.willCloseNotification` observer
- `WebContentView` holds transient per-document state: `remainingChunks`, `hasMermaid`, `isMonospace`
- `mermaidJS` is cached as a class-level static (`private static var mermaidJS: String?`) — loaded once, reused across all documents
- `SplitTemplate` is loaded once at app launch, shared across all `openFile` calls

## Key Abstractions

**RenderResult:**
- Purpose: Immutable value type carrying the output of one full rendering pass
- Examples: `MDViewer/MarkdownRenderer.swift` (lines 5-9)
- Pattern: Struct with three fields — `page: String` (first chunk wrapped in template), `remainingChunks: [String]`, `hasMermaid: Bool`

**SplitTemplate:**
- Purpose: Pre-split HTML template to avoid string scanning at render time
- Examples: `MDViewer/MarkdownRenderer.swift` (lines 12-26)
- Pattern: Struct initialized by splitting `template.html` at `{{FIRST_CHUNK}}`; stores `prefix` and `suffix` strings for O(1) concatenation

**WebContentViewDelegate:**
- Purpose: Callback protocol so `AppDelegate` can react to the first paint event without a tight coupling to WKWebView internals
- Examples: `MDViewer/WebContentView.swift` (lines 4-6), `MDViewer/AppDelegate.swift` (line 79)
- Pattern: Single-method delegate with `weak` reference in `WebContentView`

**MarkdownRenderer:**
- Purpose: Stateless renderer (no stored document state) — thread-safe by design
- Examples: `MDViewer/MarkdownRenderer.swift`
- Pattern: `final class` with only two compiled regexes as class-level statics

## Entry Points

**Application Entry:**
- Location: `MDViewer/main.swift`
- Triggers: OS launch
- Responsibilities: Creates `NSApplication.shared`, instantiates `AppDelegate`, starts run loop

**File Open (Finder/Dock):**
- Location: `AppDelegate.application(_:open:)` in `MDViewer/AppDelegate.swift` (line 33)
- Triggers: User double-clicks `.md` file or drags onto Dock icon
- Responsibilities: Sets `openedViaDelegate = true`, calls `openFile` for each URL

**File Open (CLI):**
- Location: `AppDelegate.applicationDidFinishLaunching(_:)` in `MDViewer/AppDelegate.swift` (line 12)
- Triggers: App launched with a file path as `argv[1]`
- Responsibilities: Reads `ProcessInfo.processInfo.arguments[1]`, constructs URL, calls `openFile`

**File Open (Menu/Panel):**
- Location: `AppDelegate.openDocument(_:)` in `MDViewer/AppDelegate.swift` (line 51)
- Triggers: `Cmd+O`
- Responsibilities: Shows `NSOpenPanel` filtered to `.md`/`.markdown`, calls `openFile` for selected URLs

## Error Handling

**Strategy:** Fail-fast with user-visible alerts for file read errors; silent fallback strings for cmark parser failures.

**Patterns:**
- `MarkdownRenderer.renderFullPage(fileURL:template:)` returns `RenderResult?` — `nil` on file read failure
- `AppDelegate.openFile(_:)` shows an `NSAlert` modal when result is `nil`
- `MarkdownRenderer.parseMarkdownToHTML(_:)` returns inline error HTML strings (`"<p>Failed to create parser.</p>"`) if cmark calls return `nil` — these are rare and indicate memory exhaustion
- `WebContentView.loadAndInitMermaid()` silently skips Mermaid rendering if the bundle resource is missing

## Cross-Cutting Concerns

**Logging:** None — no logging framework or `os_log` calls anywhere in the codebase.
**Validation:** File extension filtering at `NSOpenPanel` level only (`UTType` for `.md`/`.markdown`); no content validation.
**Authentication:** Not applicable — local file viewer with no network access or user accounts.
**Threading:** Background rendering via `DispatchQueue.global(qos: .userInitiated)`; all UI on main thread enforced manually with `DispatchQueue.main.async`.

---

*Architecture analysis: 2026-04-03*
