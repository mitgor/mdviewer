<!-- GSD:project-start source:PROJECT.md -->
## Project

**MDViewer**

A fast, native macOS markdown viewer with LaTeX-inspired typography and Mermaid diagram support. Designed as a Finder-native quick preview tool — double-click a `.md` file, read it, close it. Built with AppKit + WKWebView + cmark-gfm.

**Core Value:** Open a markdown file and see beautifully rendered content instantly — sub-200ms to first visible content.

### Constraints

- **Platform**: macOS 13+ (uses cmark-gfm SPM, WKWebView features)
- **No network**: All resources bundled (fonts, mermaid.min.js)
- **Read-only**: No file modification, no state persistence
- **Speed**: First content visible in <200ms
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Swift 5.9 - All application source code (`MDViewer/*.swift`)
- HTML/CSS/JavaScript - Rendering template (`MDViewer/Resources/template.html`)
## Runtime
- macOS 13.0+ (Ventura minimum deployment target)
- Native macOS application — no server, no browser runtime
- Swift Package Manager (SPM) — dependency resolution via Xcode integration
- Lockfile: `MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (present)
## Frameworks
- `Cocoa` / `AppKit` — Window management, menus, NSApplication lifecycle (`AppDelegate.swift`, `MarkdownWindow.swift`)
- `WebKit` (`WKWebView`) — HTML rendering engine for markdown display (`WebContentView.swift`)
- `QuartzCore` — Layer-backed views, high-refresh-rate display support (`MarkdownWindow.swift`)
- `Foundation` — File I/O, regex, URL handling (`MarkdownRenderer.swift`)
- `UniformTypeIdentifiers` — UTType for `.md`/`.markdown` file associations (`AppDelegate.swift`)
- `XCTest` — Unit test framework; test target `MDViewerTests` (`MDViewerTests/MarkdownRendererTests.swift`)
- Xcode (primary IDE) — `MDViewer.xcodeproj`
- XcodeGen — `project.yml` defines project structure (generates `project.pbxproj`)
## Key Dependencies
- `swift-cmark` (`gfm` branch, revision `924936d`) — GitHub-flavored Markdown parsing and HTML rendering
- `mermaid.min.js` — Diagram rendering library, loaded on-demand from bundle
- Latin Modern Roman (regular, bold) — `MDViewer/Resources/fonts/lmroman10-regular.woff2`, `lmroman10-bold.woff2`
- Latin Modern Mono (regular) — `MDViewer/Resources/fonts/lmmono10-regular.woff2`
- Served from bundle's resource URL as base URL for WKWebView
## Configuration
- No environment variables — fully self-contained native app
- No `.env` files present
- `project.yml` — XcodeGen project definition (deployment target, Swift version, targets, SPM deps)
- `Package.swift` — SPM manifest for `MDViewerDeps` target (used by Xcode to resolve `swift-cmark`)
- `MDViewer/Info.plist` — App bundle metadata: bundle ID `com.mdviewer.app`, version `1.0`, document type associations for `.md`/`.markdown`
## Platform Requirements
- macOS with Xcode
- XcodeGen (optional — `project.yml` present; `project.pbxproj` already generated)
- No Node.js, no Python, no other runtimes required
- macOS 13.0+ (Ventura)
- Distribution: direct `.app` bundle (no App Store entitlements or sandboxing detected)
- Code-signed: `MDViewer.app/Contents/_CodeSignature/CodeResources` present in built app
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- PascalCase matching the primary type they define: `AppDelegate.swift`, `MarkdownRenderer.swift`, `MarkdownWindow.swift`, `WebContentView.swift`
- Test files mirror source files with a `Tests` suffix: `MarkdownRendererTests.swift`
- PascalCase: `MarkdownRenderer`, `SplitTemplate`, `RenderResult`, `WebContentViewDelegate`
- Protocols named after the role/behavior they describe: `WebContentViewDelegate`
- camelCase: `renderFullPage`, `loadContent`, `toggleMonospace`, `showWithFadeIn`
- `@objc` action methods follow AppKit convention: `openDocument(_:)`, `printDocument(_:)`, `toggleMonospace(_:)`
- Private helpers use descriptive camelCase: `ensureTemplateLoaded`, `injectRemainingChunks`, `loadAndInitMermaid`
- camelCase: `chunkThreshold`, `remainingChunks`, `hasMermaid`, `openedViaDelegate`
- Boolean properties use `is`/`has` prefix: `hasMermaid`, `isMonospace`, `mermaidJSLoaded`
- Static constants use camelCase: `defaultSize`, `frameSaveKey`
- Static `let` on the owning type: `MarkdownWindow.defaultSize`, `MarkdownWindow.frameSaveKey`
- Module-level constants avoided; all constants are scoped to their type
## Access Control
- `private` for implementation details within a type
- `private(set)` not used — internal mutation controlled through methods
- `weak` used for delegate references to prevent retain cycles: `weak var delegate: WebContentViewDelegate?`
- `final` on concrete classes that are not designed for subclassing: `final class MarkdownRenderer`, `final class MarkdownWindow`, `final class WebContentView`
## Type Design
- Value types used for pure data: `RenderResult`, `SplitTemplate`
- No mutating methods on structs — all fields are `let`
- `AppDelegate`, `MarkdownWindow`, `WebContentView`, `MarkdownRenderer` are all classes
- Delegate protocols declared with `AnyObject` constraint: `protocol WebContentViewDelegate: AnyObject`
- Single delegate property on view types, held `weak`
## MARK Organization
## Import Organization
## Error Handling
- `guard let x = try? ...` for operations that can fail silently, returning `nil` to caller: `guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }`
- `fatalError` for programmer errors and unrecoverable startup conditions: `fatalError("template.html not found in bundle")`, `fatalError("init(coder:) not supported")`
- `NSAlert` for user-facing file errors shown on the main thread
- `defer` for C resource cleanup when using cmark C API: `defer { cmark_parser_free(parser) }`, `defer { cmark_node_free(root) }`, `defer { free(htmlCStr) }`
## Concurrency
- Always capture `[weak self]` in closures that reference `self` to avoid retain cycles
- Main thread dispatch used for all UI mutations and `NSAlert` presentation
- `DispatchQueue.main.async` used in `applicationDidFinishLaunching` to defer argument-based file opening until after delegate setup
## Memory Management
- `[weak self]` used in all closures that capture `self` where a retain cycle is possible
- `isReleasedWhenClosed = false` on `NSWindow` subclass — windows managed manually in `AppDelegate.windows` array
- Window cleanup via `NotificationCenter` observer on `NSWindow.willCloseNotification`
## Comments
- Inline comments explain non-obvious performance decisions: `// Parse markdown on background thread — keeps UI responsive for large files`
- Doc comments (`///`) on types and methods where purpose is not self-evident
- Single-line comments with `//` for implementation notes
## Regex
## Function Design
- Functions are small and single-purpose; helper logic extracted into `private` methods
- Methods return early with `guard` rather than nesting: `guard let tmpl = template else { return }`
- Parameters kept minimal; complex data passed as structs (`SplitTemplate`, `RenderResult`)
## Module Design
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- No view model layer — `AppDelegate` owns all coordination logic between file I/O, rendering, and windowing
- Rendering is offloaded to a background thread; all UI mutations happen on the main thread
- WKWebView is used as the rendering surface; Swift ↔ JavaScript communication is bidirectional via `WKScriptMessageHandler` and `evaluateJavaScript`
- Content is split into chunks at render time to keep initial paint fast; remaining content is injected asynchronously after the first paint signal
## Layers
- Purpose: App lifecycle, menu construction, file open coordination, window management
- Location: `MDViewer/AppDelegate.swift`
- Contains: `NSApplicationDelegate`, `WebContentViewDelegate` conformances, window array, template loading
- Depends on: `MarkdownRenderer`, `MarkdownWindow`, `WebContentView`, `SplitTemplate`, `RenderResult`
- Used by: macOS (entry point via `MDViewer/main.swift`)
- Purpose: Parse markdown to HTML using cmark-gfm, detect and transform Mermaid blocks, split output into progressive chunks
- Location: `MDViewer/MarkdownRenderer.swift`
- Contains: `MarkdownRenderer` class, `RenderResult` struct, `SplitTemplate` struct
- Depends on: `cmark_gfm`, `cmark_gfm_extensions` (C libraries via Swift Package)
- Used by: `AppDelegate.openFile(_:)` on a background `DispatchQueue`
- Purpose: Host and control the WKWebView, manage progressive content injection, handle JS ↔ native messaging
- Location: `MDViewer/WebContentView.swift`
- Contains: `WebContentView` (NSView subclass), `WebContentViewDelegate` protocol
- Depends on: WebKit, `WKWebView`, `WKScriptMessageHandler`
- Used by: `AppDelegate.displayResult(_:for:)`
- Purpose: Wrap WebContentView in a styled NSWindow with fade-in animation and ProMotion configuration
- Location: `MDViewer/MarkdownWindow.swift`
- Contains: `MarkdownWindow` (NSWindow subclass)
- Depends on: Cocoa, QuartzCore
- Used by: `AppDelegate.displayResult(_:for:)`
- Purpose: HTML shell with embedded CSS, JavaScript progressive loading logic, and Mermaid initialization
- Location: `MDViewer/Resources/template.html`, `MDViewer/Resources/mermaid.min.js`, `MDViewer/Resources/fonts/`
- Contains: Full page HTML, all styling, `appendChunk`, `initMermaid`, `toggleMonospace` JS functions
- Used by: `SplitTemplate` (split at `{{FIRST_CHUNK}}` marker at load time), `WebContentView.loadAndInitMermaid()`
## Data Flow
- `AppDelegate` holds an array of open `MarkdownWindow` instances (`windows: [MarkdownWindow]`)
- Windows are removed from the array via `NSWindow.willCloseNotification` observer
- `WebContentView` holds transient per-document state: `remainingChunks`, `hasMermaid`, `isMonospace`
- `mermaidJS` is cached as a class-level static (`private static var mermaidJS: String?`) — loaded once, reused across all documents
- `SplitTemplate` is loaded once at app launch, shared across all `openFile` calls
## Key Abstractions
- Purpose: Immutable value type carrying the output of one full rendering pass
- Examples: `MDViewer/MarkdownRenderer.swift` (lines 5-9)
- Pattern: Struct with three fields — `page: String` (first chunk wrapped in template), `remainingChunks: [String]`, `hasMermaid: Bool`
- Purpose: Pre-split HTML template to avoid string scanning at render time
- Examples: `MDViewer/MarkdownRenderer.swift` (lines 12-26)
- Pattern: Struct initialized by splitting `template.html` at `{{FIRST_CHUNK}}`; stores `prefix` and `suffix` strings for O(1) concatenation
- Purpose: Callback protocol so `AppDelegate` can react to the first paint event without a tight coupling to WKWebView internals
- Examples: `MDViewer/WebContentView.swift` (lines 4-6), `MDViewer/AppDelegate.swift` (line 79)
- Pattern: Single-method delegate with `weak` reference in `WebContentView`
- Purpose: Stateless renderer (no stored document state) — thread-safe by design
- Examples: `MDViewer/MarkdownRenderer.swift`
- Pattern: `final class` with only two compiled regexes as class-level statics
## Entry Points
- Location: `MDViewer/main.swift`
- Triggers: OS launch
- Responsibilities: Creates `NSApplication.shared`, instantiates `AppDelegate`, starts run loop
- Location: `AppDelegate.application(_:open:)` in `MDViewer/AppDelegate.swift` (line 33)
- Triggers: User double-clicks `.md` file or drags onto Dock icon
- Responsibilities: Sets `openedViaDelegate = true`, calls `openFile` for each URL
- Location: `AppDelegate.applicationDidFinishLaunching(_:)` in `MDViewer/AppDelegate.swift` (line 12)
- Triggers: App launched with a file path as `argv[1]`
- Responsibilities: Reads `ProcessInfo.processInfo.arguments[1]`, constructs URL, calls `openFile`
- Location: `AppDelegate.openDocument(_:)` in `MDViewer/AppDelegate.swift` (line 51)
- Triggers: `Cmd+O`
- Responsibilities: Shows `NSOpenPanel` filtered to `.md`/`.markdown`, calls `openFile` for selected URLs
## Error Handling
- `MarkdownRenderer.renderFullPage(fileURL:template:)` returns `RenderResult?` — `nil` on file read failure
- `AppDelegate.openFile(_:)` shows an `NSAlert` modal when result is `nil`
- `MarkdownRenderer.parseMarkdownToHTML(_:)` returns inline error HTML strings (`"<p>Failed to create parser.</p>"`) if cmark calls return `nil` — these are rare and indicate memory exhaustion
- `WebContentView.loadAndInitMermaid()` silently skips Mermaid rendering if the bundle resource is missing
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
