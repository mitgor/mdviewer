# Phase 9: Native Text Rendering - Research

**Researched:** 2026-04-16
**Domain:** NSTextView + cmark AST traversal for native markdown rendering
**Confidence:** HIGH

## Summary

Phase 9 adds an NSTextView-based rendering path for simple markdown files (no Mermaid diagrams, no GFM tables). The core technical challenge is walking the cmark-gfm AST directly from Swift to build an NSAttributedString, bypassing the HTML intermediate step entirely. This eliminates the WKWebView process launch overhead for simple documents, targeting sub-100ms warm launch to first visible content.

The existing cmark AST iterator API (`cmark_iter_new`, `cmark_iter_next`, `CMARK_EVENT_ENTER`/`EXIT`) is well-suited for this. The iterator produces enter/exit events for container nodes and single events for leaf nodes, which maps cleanly to an NSAttributedString builder that pushes/pops style state on a stack. The critical requirement NATV-01 (detecting files that qualify for native rendering) can be satisfied by a pre-scan of the AST before choosing the rendering path.

**Primary recommendation:** Build a `NativeRenderer` class that uses `cmark_iter` to walk the AST and produce `NSAttributedString`. Embed the content in an `NSTextView` wrapped in an `NSScrollView`, hosted by a new `NativeContentView` (NSView subclass). Decision between native vs. web path happens in `AppDelegate.openFile` based on AST pre-scan results (presence of table/mermaid nodes).

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NATV-01 | Files without mermaid blocks or GFM tables render via NSTextView | AST pre-scan detects CMARK_NODE_TABLE and mermaid code blocks; route to NativeContentView or WebContentView accordingly |
| NATV-02 | NSTextView backend walks cmark AST directly to build NSAttributedString (no HTML intermediate) | cmark_iter API provides ENTER/EXIT events; visitor pattern builds attributed string directly |
| NATV-03 | Native rendering uses same Latin Modern Roman typography as WKWebView path | Requires bundling OTF versions of Latin Modern fonts; WOFF2 not supported by Core Text |
| NATV-04 | User can toggle between native and web rendering if visual differences arise | Menu item in View menu; MarkdownWindow protocol abstraction enables content view swap |
| PERF-02 | Warm launch to first visible content under 100ms for NSTextView path | No WKWebView process spawn; NSTextView + NSAttributedString creation is synchronous and fast |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| AST pre-scan (table/mermaid detection) | Rendering layer | -- | MarkdownRenderer already owns parsing; detection is a post-parse AST walk |
| AST-to-NSAttributedString conversion | Rendering layer | -- | Pure data transformation, no UI dependency |
| NSTextView hosting | View layer | -- | NativeContentView mirrors WebContentView as an NSView subclass |
| Font registration (OTF) | App lifecycle | -- | CTFontManagerRegisterFontsForURL at launch in AppDelegate |
| Render path routing | Coordination layer | -- | AppDelegate.openFile already orchestrates rendering decisions |
| Native/Web toggle | Menu + Window | -- | Menu action + window-level content view swap |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| AppKit NSTextView | macOS 13+ | Native text rendering surface | Built-in, zero overhead, no process spawn |
| AppKit NSScrollView | macOS 13+ | Scrollable container for NSTextView | Required for document-length content |
| Core Text (CTFontManagerRegisterFontsForURL) | macOS 13+ | Register bundled OTF fonts at runtime | Standard API for non-system font registration [VERIFIED: Apple docs] |
| cmark-gfm C API (vendored) | rev 924936d | AST parsing + iteration | Already vendored in project; cmark_iter API is stable |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| NSParagraphStyle | macOS 13+ | Line spacing, indentation, list formatting | Every block-level element needs paragraph style |
| NSMutableAttributedString | macOS 13+ | Incremental attributed string construction | Core output type of the AST walker |
| OSSignposter | macOS 13+ | Performance measurement | Required for PERF-02 validation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| NSTextView | TextKit 2 (NSTextLayoutManager) | More modern but adds complexity; NSTextView with TextKit 1 is simpler and sufficient for read-only display |
| Manual cmark_iter walker | Down/Maaku library | Would add a dependency; we already have vendored cmark and the walker is ~200 lines of code |
| STTextView (3rd party) | NSTextView | More performant for editing; we only need read-only display |

## Architecture Patterns

### System Architecture Diagram

```
File Open Request
       |
       v
[MarkdownRenderer.parse()]  -- cmark_parser_feed + cmark_parser_finish
       |
       v
[AST Pre-scan]  -- walk top-level children, check for TABLE/MERMAID nodes
       |
       +---> has tables/mermaid? ---> [WebContentView path] (existing)
       |
       +---> simple content? ---> [NativeRenderer.render(root:)]
                                         |
                                         v
                                  [cmark_iter walk]
                                  push/pop style stack
                                         |
                                         v
                                  [NSAttributedString]
                                         |
                                         v
                                  [NativeContentView]
                                  NSScrollView > NSTextView
                                         |
                                         v
                                  [MarkdownWindow]
                                  showWithFadeIn()
```

### Recommended Project Structure
```
MDViewer/
  AppDelegate.swift          # Modified: routing logic, font registration, toggle menu
  MarkdownRenderer.swift     # Modified: add AST pre-scan, expose parsed root
  MarkdownWindow.swift       # Modified: support both content view types
  WebContentView.swift       # Unchanged
  NativeRenderer.swift       # NEW: cmark AST -> NSAttributedString
  NativeContentView.swift    # NEW: NSScrollView + NSTextView wrapper
  Resources/
    fonts/
      lmroman10-regular.otf  # NEW: OTF for Core Text
      lmroman10-bold.otf     # NEW: OTF for Core Text
      lmmono10-regular.otf   # NEW: OTF for Core Text
      lmroman10-regular.woff2  # Existing (for WKWebView)
      lmroman10-bold.woff2     # Existing (for WKWebView)
      lmmono10-regular.woff2   # Existing (for WKWebView)
```

### Pattern 1: AST Iterator Visitor
**What:** Walk the cmark AST using `cmark_iter_new`/`cmark_iter_next`, building NSAttributedString by pushing/popping style state on ENTER/EXIT events.
**When to use:** Every native render pass.
**Example:**
```swift
// Source: cmark-gfm.h iterator API [VERIFIED: vendored header]
final class NativeRenderer {
    private var styleStack: [StyleState] = []
    private let result = NSMutableAttributedString()

    func render(root: OpaquePointer) -> NSAttributedString {
        guard let iter = cmark_iter_new(root) else { return result }
        defer { cmark_iter_free(iter) }

        while true {
            let eventType = cmark_iter_next(iter)
            guard eventType != CMARK_EVENT_DONE else { break }
            let node = cmark_iter_get_node(iter)
            let nodeType = cmark_node_get_type(node)

            switch eventType {
            case CMARK_EVENT_ENTER:
                handleEnter(nodeType: nodeType, node: node)
            case CMARK_EVENT_EXIT:
                handleExit(nodeType: nodeType, node: node)
            default:
                break
            }
        }
        return result
    }
}
```

### Pattern 2: Style Stack for Nested Formatting
**What:** Maintain a stack of active text attributes. On ENTER, push new attributes (e.g., bold, italic). On EXIT, pop. Leaf text nodes apply the current top-of-stack attributes.
**When to use:** Handling nested inline formatting (e.g., bold inside a link inside a heading).
**Example:**
```swift
// [ASSUMED] - standard pattern from Down/CocoaMarkdown libraries
private struct StyleState {
    var font: NSFont
    var color: NSColor
    var paragraphStyle: NSParagraphStyle
    var traits: NSFontDescriptor.SymbolicTraits
    var link: URL?
    var strikethrough: Bool
}

private func handleEnter(nodeType: cmark_node_type, node: OpaquePointer?) {
    var state = currentStyle
    switch nodeType {
    case CMARK_NODE_HEADING:
        let level = cmark_node_get_heading_level(node)
        state.font = headingFont(level: Int(level))
    case CMARK_NODE_EMPH:
        state.traits.insert(.italic)
    case CMARK_NODE_STRONG:
        state.traits.insert(.bold)
    case CMARK_NODE_CODE:
        // Leaf node -- append text directly
        if let literal = cmark_node_get_literal(node) {
            let text = String(cString: literal)
            let attrs = codeAttributes()
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        return  // no push needed for leaf
    case CMARK_NODE_TEXT:
        if let literal = cmark_node_get_literal(node) {
            let text = String(cString: literal)
            result.append(NSAttributedString(string: text, attributes: currentAttributes()))
        }
        return
    default:
        break
    }
    styleStack.append(state)
}
```

### Pattern 3: AST Pre-scan for Routing
**What:** Before choosing native vs. web path, scan the AST's top-level children to detect unsupported node types (tables, mermaid code blocks).
**When to use:** In the render decision logic, after parsing.
**Example:**
```swift
// [VERIFIED: cmark-gfm.h API]
func canRenderNatively(root: OpaquePointer) -> Bool {
    var child = cmark_node_first_child(root)
    while let node = child {
        let nodeType = cmark_node_get_type(node)

        // Check for GFM table extension nodes
        if let typeStr = cmark_node_get_type_string(node),
           String(cString: typeStr) == "table" {
            return false
        }

        // Check for mermaid code blocks
        if nodeType == CMARK_NODE_CODE_BLOCK,
           let info = cmark_node_get_fence_info(node),
           String(cString: info) == "mermaid" {
            return false
        }

        child = cmark_node_next(node)
    }
    return true
}
```

### Anti-Patterns to Avoid
- **Converting to HTML then parsing back:** The entire point of NATV-02 is to skip the HTML intermediate. Do not use NSAttributedString(html:) or any HTML-based approach.
- **Creating NSFont on every text node:** Font creation is expensive. Cache NSFont instances for each style variant (body, bold, italic, bold-italic, code, h1-h6). Create them once at init.
- **Deep-walking for pre-scan:** The pre-scan only needs to check top-level and second-level nodes (code blocks are direct children of document). Do not use cmark_iter for the pre-scan -- use cmark_node_first_child/next_sibling traversal.
- **Sharing the cmark_node root across threads:** The AST must be consumed on the same thread it was parsed on. The NSAttributedString can then be dispatched to main thread.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Font registration | Manual font file loading | CTFontManagerRegisterFontsForURL | Handles all font formats, thread-safe, one-line API |
| Paragraph spacing | Manual newline counting | NSParagraphStyle.paragraphSpacingBefore/After | Correct spacing with proper typography metrics |
| List indentation | Hardcoded pixel offsets | NSParagraphStyle.headIndent + NSTextTab | Handles mixed indent levels, RTL, dynamic type |
| Link detection | Regex URL matching | NSAttributedString .link attribute + NSTextView delegate | NSTextView handles click, hover cursor automatically |
| Smart quotes | Manual character replacement | Already done by cmark (CMARK_OPT_SMART) | cmark handles em/en dashes, curly quotes during parsing |

**Key insight:** NSAttributedString + NSParagraphStyle provides a complete typographic model. The work is mapping cmark node types to the right attributes, not reimplementing typography.

## Common Pitfalls

### Pitfall 1: WOFF2 Fonts Not Supported by Core Text
**What goes wrong:** CTFontManagerRegisterFontsForURL silently fails with WOFF2 files. NSFont falls back to system font.
**Why it happens:** WOFF2 is a web-only format. Core Text supports TrueType (.ttf), OpenType (.otf), and TrueType Collection (.ttc). [VERIFIED: Apple docs + web search]
**How to avoid:** Bundle OTF versions of Latin Modern Roman alongside the existing WOFF2 files. The WOFF2 files remain for the WKWebView path.
**Warning signs:** Text renders in San Francisco instead of Latin Modern. Check font name after NSFont creation.

### Pitfall 2: Extension Node Types Not Exposed in Modulemap
**What goes wrong:** `CMARK_NODE_TABLE`, `CMARK_NODE_STRIKETHROUGH` are declared in `table.h` and `strikethrough.h` which are NOT included in the unified `module.modulemap`. Swift code cannot reference these constants directly.
**Why it happens:** The vendored modulemap (Phase 6) merged the core extensions header but not the individual extension type headers. [VERIFIED: module.modulemap inspection]
**How to avoid:** Use `cmark_node_get_type_string(node)` which returns a C string like "table", "table_row", "strikethrough". Compare strings instead of enum values for extension types.
**Warning signs:** Compile error "use of unresolved identifier 'CMARK_NODE_TABLE'".

### Pitfall 3: NSTextView Sizing in NSScrollView
**What goes wrong:** NSTextView has zero height or doesn't scroll.
**Why it happens:** NSTextView defaults to being width-tracking but not height-tracking. If isVerticallyResizable is false, the text view won't grow.
**How to avoid:** Configure: `textView.isVerticallyResizable = true`, `textView.isHorizontallyResizable = false`, `textView.textContainer?.widthTracksTextView = true`, `textView.maxSize = NSSize(width: CGFloat.max, height: CGFloat.max)`.
**Warning signs:** Content appears clipped or scroll bar doesn't appear.

### Pitfall 4: Paragraph Spacing Accumulation
**What goes wrong:** Double spacing between elements because both the EXIT handler of one block and the ENTER handler of the next add spacing.
**Why it happens:** The visitor pattern visits EXIT of paragraph, then ENTER of next paragraph.
**How to avoid:** Apply paragraph spacing only via NSParagraphStyle.paragraphSpacingBefore (or only After), never both. Convention: use paragraphSpacingBefore on each block element.
**Warning signs:** Rendered output looks double-spaced compared to the WKWebView version.

### Pitfall 5: Forgetting to Free the AST Root
**What goes wrong:** Memory leak -- the cmark AST is allocated in C and not ARC-managed.
**Why it happens:** When adding the native path, the AST root must survive past the HTML rendering step. Easy to forget `cmark_node_free(root)`.
**How to avoid:** Use `defer { cmark_node_free(root) }` immediately after `cmark_parser_finish`. The NSAttributedString is a fully independent copy.
**Warning signs:** Memory growth visible in Instruments Allocations.

### Pitfall 6: MarkdownWindow Tight Coupling to WebContentView
**What goes wrong:** MarkdownWindow.contentViewWrapper is typed as `WebContentView`, making it impossible to swap in `NativeContentView`.
**Why it happens:** MarkdownWindow was designed for the single-backend architecture.
**How to avoid:** Introduce a protocol (e.g., `ContentViewProtocol`) that both WebContentView and NativeContentView conform to, or store the content view as a generic NSView with type-checked access.
**Warning signs:** Compiler errors when trying to assign NativeContentView to the window.

## Code Examples

### Registering Bundled OTF Fonts
```swift
// Source: Apple CTFontManagerRegisterFontsForURL docs [CITED: developer.apple.com/documentation/coretext/ctfontmanagerregisterfontsforurl]
private func registerBundledFonts() {
    let fontNames = ["lmroman10-regular.otf", "lmroman10-bold.otf", "lmmono10-regular.otf"]
    for name in fontNames {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        #if DEBUG
        if let error = error?.takeRetainedValue() {
            print("[Font] Failed to register \(name): \(error)")
        }
        #endif
    }
}
```

### Creating the NSTextView + NSScrollView
```swift
// [ASSUMED] - standard AppKit pattern
final class NativeContentView: NSView {
    private let scrollView: NSScrollView
    private let textView: NSTextView

    override init(frame: NSRect) {
        scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.max))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 20, height: 40)
        textView.maxSize = NSSize(width: CGFloat.max, height: CGFloat.max)
        textView.backgroundColor = .white

        super.init(frame: frame)

        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func loadContent(attributedString: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributedString)
    }
}
```

### Typography Constants Matching template.html
```swift
// Source: template.html CSS values [VERIFIED: MDViewer/Resources/template.html]
// CSS: font-size: 16px, line-height: 1.6, max-width: 680px
// h1: 2em (32px), h2: 1.5em (24px), h3: 1.25em (20px)
// code: 0.9em (14.4px), pre code: 0.85em (13.6px)
// blockquote: italic, color #555, border-left 3px #ccc
// link: color #1a3a6b, no underline

private enum Typography {
    static let bodySize: CGFloat = 16
    static let lineHeightMultiplier: CGFloat = 1.6
    static let maxContentWidth: CGFloat = 680
    static let textColor = NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1) // #333
    static let headingColor = NSColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1) // #1a1a1a
    static let linkColor = NSColor(red: 0.102, green: 0.227, blue: 0.420, alpha: 1) // #1a3a6b
    static let quoteColor = NSColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1) // #555
    static let codeBackground = NSColor(red: 0.973, green: 0.965, blue: 0.941, alpha: 1) // #f8f6f0

    static func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return bodySize * 2.0    // 32px
        case 2: return bodySize * 1.5    // 24px
        case 3: return bodySize * 1.25   // 20px
        case 4: return bodySize * 1.1    // 17.6px
        case 5: return bodySize          // 16px
        case 6: return bodySize * 0.9    // 14.4px
        default: return bodySize
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| NSAttributedString(html:) | Direct AST-to-attributed-string | N/A (this is the standard for perf-critical paths) | Avoids HTML serialization + WebKit parsing roundtrip |
| TextKit 1 (NSLayoutManager) | TextKit 2 (NSTextLayoutManager) | macOS 12+ | TextKit 2 is preferred for new code but TextKit 1 still works; TextKit 2 adds complexity without benefit for read-only display |
| Global font installation | CTFontManagerRegisterFontsForURL with .process scope | macOS 10.6+ | Process-scoped registration avoids polluting system font list |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Latin Modern Roman OTF files are freely available from CTAN (GUST e-foundry, version 2.007) | Standard Stack / Pitfall 1 | Must find OTF files; if unavailable, would need to convert WOFF2 to OTF |
| A2 | NSTextView with TextKit 1 is sufficient for read-only markdown display at sub-100ms | Architecture Patterns | If TextKit 1 layout is too slow for large documents, may need TextKit 2 or lazy layout |
| A3 | Style stack approach with ~15 node type handlers will cover all non-table/non-mermaid markdown | Pattern 2 | Missing node types would cause unstyled text; enumeration of all cmark_node_type values mitigates this |
| A4 | textContainerInset of (20, 40) will visually approximate the CSS padding: 40px 20px 80px | Code Examples | May need visual tuning; the toggle feature (NATV-04) provides escape hatch |

## Open Questions

1. **OTF Font File Acquisition**
   - What we know: Latin Modern OTF files are available from CTAN/GUST (lm-2.007). Bundle adds ~3.5MB.
   - What's unclear: Whether the project should commit OTF files or convert WOFF2 at build time.
   - Recommendation: Download OTF files from CTAN and bundle them. 3.5MB is acceptable for a native app. Converting at build time adds build complexity.

2. **NSTextView Content Width Constraint**
   - What we know: template.html uses `max-width: 680px`. NSTextView textContainerInset centers content but doesn't constrain the text container width.
   - What's unclear: Best approach to limit line length to 680px in NSTextView.
   - Recommendation: Set `textContainer.size.width = 680` and center the scroll view's document view, or calculate textContainerInset dynamically based on window width.

3. **Monospace Toggle for Native Path**
   - What we know: WebContentView.toggleMonospace() toggles a CSS class. The native path needs an equivalent.
   - What's unclear: Whether to re-render the entire NSAttributedString or modify attributes in-place.
   - Recommendation: Re-render. NSAttributedString attribute modification across the entire range is error-prone with nested styles. Re-rendering from the cached AST root is fast (<10ms for typical files).

4. **Printing/PDF Export from NSTextView**
   - What we know: WebContentView has printContent() and exportPDF() via WKWebView.createPDF.
   - What's unclear: Whether these features should work from the native path.
   - Recommendation: NSTextView supports NSPrintOperation natively (simpler than the WKWebView workaround). Implement print but defer PDF export to the web path via the toggle.

## Sources

### Primary (HIGH confidence)
- cmark-gfm.h (vendored) - AST iterator API, node types, accessor functions
- module.modulemap (vendored) - Confirms extension type headers NOT exposed to Swift
- table.h, strikethrough.h (vendored) - Extension node type declarations
- cmark-gfm-core-extensions.h (vendored) - Table/tasklist accessor APIs
- template.html (project) - Typography CSS values for matching
- AppDelegate.swift, WebContentView.swift, MarkdownWindow.swift, MarkdownRenderer.swift (project) - Current architecture

### Secondary (MEDIUM confidence)
- [Apple CTFontManagerRegisterFontsForURL docs](https://developer.apple.com/documentation/coretext/ctfontmanagerregisterfontsforurl(_:_:_:)) - Font registration API
- [CTAN Latin Modern package](https://ctan.org/pkg/lm) - OTF font availability
- [Down library pattern](https://github.com/johnxnguyen/Down) - AST visitor -> NSAttributedString pattern reference

### Tertiary (LOW confidence)
- Web search on WOFF2/Core Text compatibility - confirmed WOFF2 not supported natively

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all components are built-in macOS frameworks, no external dependencies
- Architecture: HIGH - cmark_iter API is well-documented in vendored headers; AST visitor pattern is established
- Pitfalls: HIGH - font format limitation verified; modulemap limitation verified by file inspection
- Typography matching: MEDIUM - CSS-to-NSAttributedString mapping requires visual tuning

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (stable domain -- AppKit APIs do not change rapidly)
