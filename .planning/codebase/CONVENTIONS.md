# Coding Conventions

**Analysis Date:** 2026-04-03

## Naming Patterns

**Files:**
- PascalCase matching the primary type they define: `AppDelegate.swift`, `MarkdownRenderer.swift`, `MarkdownWindow.swift`, `WebContentView.swift`
- Test files mirror source files with a `Tests` suffix: `MarkdownRendererTests.swift`

**Types (classes, structs, protocols):**
- PascalCase: `MarkdownRenderer`, `SplitTemplate`, `RenderResult`, `WebContentViewDelegate`
- Protocols named after the role/behavior they describe: `WebContentViewDelegate`

**Functions and methods:**
- camelCase: `renderFullPage`, `loadContent`, `toggleMonospace`, `showWithFadeIn`
- `@objc` action methods follow AppKit convention: `openDocument(_:)`, `printDocument(_:)`, `toggleMonospace(_:)`
- Private helpers use descriptive camelCase: `ensureTemplateLoaded`, `injectRemainingChunks`, `loadAndInitMermaid`

**Variables and properties:**
- camelCase: `chunkThreshold`, `remainingChunks`, `hasMermaid`, `openedViaDelegate`
- Boolean properties use `is`/`has` prefix: `hasMermaid`, `isMonospace`, `mermaidJSLoaded`
- Static constants use camelCase: `defaultSize`, `frameSaveKey`

**Constants:**
- Static `let` on the owning type: `MarkdownWindow.defaultSize`, `MarkdownWindow.frameSaveKey`
- Module-level constants avoided; all constants are scoped to their type

## Access Control

**Pattern:** Explicit access control on all declarations.
- `private` for implementation details within a type
- `private(set)` not used — internal mutation controlled through methods
- `weak` used for delegate references to prevent retain cycles: `weak var delegate: WebContentViewDelegate?`
- `final` on concrete classes that are not designed for subclassing: `final class MarkdownRenderer`, `final class MarkdownWindow`, `final class WebContentView`

## Type Design

**Structs for data:**
- Value types used for pure data: `RenderResult`, `SplitTemplate`
- No mutating methods on structs — all fields are `let`

**Classes for objects with identity/lifecycle:**
- `AppDelegate`, `MarkdownWindow`, `WebContentView`, `MarkdownRenderer` are all classes

**Protocol delegation:**
- Delegate protocols declared with `AnyObject` constraint: `protocol WebContentViewDelegate: AnyObject`
- Single delegate property on view types, held `weak`

## MARK Organization

All source files organize sections with `// MARK: -` comments. Standard sections used:

```swift
// MARK: - App Lifecycle
// MARK: - File Opening
// MARK: - Menu Actions
// MARK: - WebContentViewDelegate
// MARK: - Private
// MARK: - WKScriptMessageHandler
```

Pattern: public/protocol-conformance sections first, `// MARK: - Private` last.

## Import Organization

Standard library/framework imports first (alphabetical), then third-party:

```swift
import Cocoa
import UniformTypeIdentifiers

import cmark_gfm
import cmark_gfm_extensions
```

No path aliases — direct module imports only.

## Error Handling

**Strategy:** Fail fast or return `nil` — no `throws`, no `Result` type used in the codebase.

**Patterns:**
- `guard let x = try? ...` for operations that can fail silently, returning `nil` to caller: `guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }`
- `fatalError` for programmer errors and unrecoverable startup conditions: `fatalError("template.html not found in bundle")`, `fatalError("init(coder:) not supported")`
- `NSAlert` for user-facing file errors shown on the main thread
- `defer` for C resource cleanup when using cmark C API: `defer { cmark_parser_free(parser) }`, `defer { cmark_node_free(root) }`, `defer { free(htmlCStr) }`

**No custom error types** are defined. Error paths are handled at the point of failure.

## Concurrency

**Pattern:** GCD (Grand Central Dispatch) — no Swift concurrency (`async`/`await`) used.

```swift
// Background work
DispatchQueue.global(qos: .userInitiated).async {
    // CPU-bound work (markdown parsing)
    DispatchQueue.main.async { [weak self] in
        // UI updates
    }
}
```

- Always capture `[weak self]` in closures that reference `self` to avoid retain cycles
- Main thread dispatch used for all UI mutations and `NSAlert` presentation
- `DispatchQueue.main.async` used in `applicationDidFinishLaunching` to defer argument-based file opening until after delegate setup

## Memory Management

- `[weak self]` used in all closures that capture `self` where a retain cycle is possible
- `isReleasedWhenClosed = false` on `NSWindow` subclass — windows managed manually in `AppDelegate.windows` array
- Window cleanup via `NotificationCenter` observer on `NSWindow.willCloseNotification`

## Comments

**When to comment:**
- Inline comments explain non-obvious performance decisions: `// Parse markdown on background thread — keeps UI responsive for large files`
- Doc comments (`///`) on types and methods where purpose is not self-evident
- Single-line comments with `//` for implementation notes

**Examples from codebase:**
```swift
/// Pre-split template for fast concatenation (no string scanning at render time).
struct SplitTemplate { ... }

/// Load mermaid.js only when the document has mermaid blocks.
/// Cached after first load — subsequent documents reuse the parsed JS.
private func loadAndInitMermaid() { ... }

/// Print and PDF export both use window.print() — the only WKWebView
func printContent() { ... }
```

**No JSDoc/TSDoc** — Swift doc comments use `///` triple-slash format.

## Regex

Static `let` precompiled regex with `try!` — acceptable because pattern correctness is a programmer invariant:

```swift
private static let mermaidRegex = try! NSRegularExpression(
    pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#
)
```

Raw string literals (`#"..."#`) used for regex patterns to avoid double-escaping.

## Function Design

- Functions are small and single-purpose; helper logic extracted into `private` methods
- Methods return early with `guard` rather than nesting: `guard let tmpl = template else { return }`
- Parameters kept minimal; complex data passed as structs (`SplitTemplate`, `RenderResult`)

## Module Design

**Exports:** No explicit public API — `@testable import MDViewer` used in tests to access internal types.

**No barrel files** — Swift does not use module re-export files; each file is a standalone compilation unit.

---

*Convention analysis: 2026-04-03*
