# Phase 6: Vendored cmark - Pattern Map

**Mapped:** 2026-04-16
**Files analyzed:** 8 new/modified files
**Analogs found:** 6 / 8

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `project.yml` | config | build-system | `project.yml` (current) | exact (modify-in-place) |
| `Package.swift` | config | build-system | `Package.swift` (current) | exact (remove/reduce) |
| `Vendor/cmark-gfm/src/html.c` | service | transform | `swift-cmark/src/html.c` (line 505-538) | exact (extend) |
| `Vendor/cmark-gfm/src/include/cmark-gfm.h` | config | API-declaration | `swift-cmark/src/include/cmark-gfm.h` | exact (extend) |
| `MDViewer/MarkdownRenderer.swift` | service | transform | `MDViewer/MarkdownRenderer.swift` (current) | exact (rewrite) |
| `MDViewerTests/MarkdownRendererTests.swift` | test | request-response | `MDViewerTests/MarkdownRendererTests.swift` (current) | exact (update) |
| `MDViewer/AppDelegate.swift` | controller | request-response | `MDViewer/AppDelegate.swift` (current) | exact (minor update) |
| `MDViewer/WebContentView.swift` | component | event-driven | `MDViewer/WebContentView.swift` (current) | exact (no change expected) |

## Pattern Assignments

### `project.yml` (config, build-system)

**Analog:** `project.yml` (current file at project root)

**Current structure** (lines 1-36):
```yaml
name: MDViewer
settings:
  base:
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    SWIFT_VERSION: "5.9"
    GENERATE_INFOPLIST_FILE: NO
packages:
  swift-cmark:
    url: https://github.com/apple/swift-cmark.git
    branch: gfm
targets:
  MDViewer:
    type: application
    platform: macOS
    sources:
      - MDViewer
    resources:
      - MDViewer/Resources
    settings:
      INFOPLIST_FILE: MDViewer/Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.mdviewer.app
    dependencies:
      - package: swift-cmark
        product: cmark-gfm
      - package: swift-cmark
        product: cmark-gfm-extensions
```

**Modification pattern:** Remove `packages:` block entirely. Replace package dependencies with target dependencies. Add two new static library targets (`cmark-gfm`, `cmark-gfm-extensions`) before the `MDViewer` target. Add `HEADER_SEARCH_PATHS` to all three targets. Add `excludes` lists matching swift-cmark's Package.swift excludes (lines 38-43 and 51-53 of swift-cmark Package.swift):
- src target excludes: `"*.re"`, `"*.in"`, `CMakeLists.txt`
- extensions target excludes: `"*.re"`, `CMakeLists.txt`

---

### `Package.swift` (config, build-system)

**Analog:** `Package.swift` (current file at project root)

**Current content** (lines 1-16):
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDViewerDeps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(name: "MDViewerDeps", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ]),
    ]
)
```

**Action:** Remove this file entirely. SPM is no longer needed. Also remove `MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` if present.

---

### `Vendor/cmark-gfm/src/html.c` (service, transform)

**Analog:** `/Users/mit/Documents/GitHub/swift-cmark/src/html.c`

**Existing render function to fork** (lines 505-538):
```c
char *cmark_render_html_with_mem(cmark_node *root, int options, cmark_llist *extensions, cmark_mem *mem) {
  char *result;
  cmark_strbuf html = CMARK_BUF_INIT(mem);
  cmark_strbuf_grow(&html, 8192);
  cmark_event_type ev_type;
  cmark_node *cur;
  cmark_html_renderer renderer = {&html, NULL, NULL, 0, 0, NULL, false, true};
  cmark_iter *iter = cmark_iter_new(root);

  for (; extensions; extensions = extensions->next)
    if (((cmark_syntax_extension *) extensions->data)->html_filter_func)
      renderer.filter_extensions = cmark_llist_append(
          mem,
          renderer.filter_extensions,
          (cmark_syntax_extension *) extensions->data);

  renderer.has_filter_extensions = (renderer.filter_extensions != NULL);

  while ((ev_type = cmark_iter_next_inline(iter)) != CMARK_EVENT_DONE) {
    cur = cmark_iter_get_node_inline(iter);
    S_render_node(&renderer, cur, ev_type, options);
  }

  if (renderer.footnote_ix) {
    cmark_strbuf_puts_lit(&html, "</ol>\n</section>\n");
  }

  result = (char *)cmark_strbuf_detach(&html);

  cmark_llist_free(mem, renderer.filter_extensions);

  cmark_iter_free(iter);
  return result;
}
```

**Chunk boundary detection point** -- after `S_render_node()` call, check:
```c
// ev_type == CMARK_EVENT_EXIT && cur->parent && cur->parent->type == CMARK_NODE_DOCUMENT
// && html.size >= chunk_byte_limit
```

**Mermaid detection insertion point** -- in `S_render_node`, `CMARK_NODE_CODE_BLOCK` case (lines 233-271). The info string parsing already exists at lines 241-245:
```c
bufsize_t first_tag = 0;
while (first_tag < node->as.code.info.len &&
       !cmark_isspace(node->as.code.info.data[first_tag])) {
    first_tag += 1;
}
```

**Opaque context field** -- `cmark_html_renderer` struct in `render.h` (line 43):
```c
void *opaque;
```
Currently `NULL` in the renderer initializer at html.c line 511. Used to pass `cmark_chunked_context*`.

**Buffer management pattern** -- use `cmark_strbuf_clear(&html)` (NOT `cmark_strbuf_free`) after each callback to reset size while keeping allocation. Final cleanup via `cmark_strbuf_detach` or `cmark_strbuf_free` after loop.

**HTML escaping for mermaid source** -- use existing `escape_html()` static function (line 26-28):
```c
static void escape_html(cmark_strbuf *dest, const unsigned char *source,
                        bufsize_t length) {
  houdini_escape_html0(dest, source, length, 0);
}
```

---

### `Vendor/cmark-gfm/src/include/cmark-gfm.h` (config, API-declaration)

**Analog:** `/Users/mit/Documents/GitHub/swift-cmark/src/include/cmark-gfm.h`

**Export macro pattern** (used throughout the header):
```c
CMARK_GFM_EXPORT
char *cmark_render_html(cmark_node *root, int options,
                        cmark_llist *extensions);

CMARK_GFM_EXPORT
char *cmark_render_html_with_mem(cmark_node *root, int options,
                                 cmark_llist *extensions, cmark_mem *mem);
```

**New declarations to add** (follow same pattern):
```c
typedef int (*cmark_html_chunk_callback)(
    const char *data, size_t len, int is_last, int has_mermaid, void *userdata);

CMARK_GFM_EXPORT
int cmark_render_html_chunked(
    cmark_node *root, int options, cmark_llist *extensions,
    cmark_mem *mem, size_t chunk_byte_limit,
    cmark_html_chunk_callback callback, void *userdata);
```

---

### `MDViewer/MarkdownRenderer.swift` (service, transform) -- MAJOR REWRITE

**Analog:** `MDViewer/MarkdownRenderer.swift` (current file)

**Import pattern** (lines 1-4):
```swift
import Foundation
import os
import cmark_gfm
import cmark_gfm_extensions
```
These imports remain unchanged -- vendored modules use the same module names.

**Current init pattern** (lines 44-46):
```swift
init() {
    cmark_gfm_core_extensions_ensure_registered()
}
```
**New init pattern** -- add extension caching:
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

**Current render flow** (lines 48-52):
```swift
func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
    let html = parseMarkdownToHTML(markdown)
    let (processed, hasMermaid) = processMermaidBlocks(html)
    return (chunkHTML(processed), hasMermaid)
}
```
**New render flow** -- single call to C chunked API, no regex passes:
```swift
func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
    // cmark_parser_new, feed, finish, then cmark_render_html_chunked
    // Callback accumulates chunks into ChunkedRenderContext
    // Returns (ctx.chunks, ctx.hasMermaid)
}
```

**C callback pattern** (new, from RESEARCH.md):
```swift
// @convention(c) callback invoked from C
let chunkCallback: @convention(c) (
    UnsafePointer<CChar>?, Int, Int32, Int32, UnsafeMutableRawPointer?
) -> Int32 = { data, len, isLast, hasMermaid, userdata in
    guard let data = data, let userdata = userdata else { return 1 }
    let ctx = Unmanaged<ChunkedRenderContext>.fromOpaque(userdata).takeUnretainedValue()
    let chunk = String(
        decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self),
            count: len
        ),
        as: UTF8.self
    )
    ctx.chunks.append(chunk)
    if hasMermaid != 0 { ctx.hasMermaid = true }
    return 0
}
```

**Error handling pattern** (lines 97-100, 122-125):
```swift
guard let parser = cmark_parser_new(options) else {
    return "<p>Failed to create parser.</p>"
}
defer { cmark_parser_free(parser) }
```

**C resource cleanup pattern** (lines 100, 113, 125):
```swift
defer { cmark_parser_free(parser) }
defer { cmark_node_free(root) }
defer { free(htmlCStr) }
```

**Signpost instrumentation pattern** (lines 64-84):
```swift
let spID = renderingSignposter.makeSignpostID()

let readState = renderingSignposter.beginInterval("file-read", id: spID)
// ... file read ...
renderingSignposter.endInterval("file-read", readState)

let parseState = renderingSignposter.beginInterval("parse", id: spID)
// ... parse ...
renderingSignposter.endInterval("parse", parseState)
```

**Methods to REMOVE:**
- `parseMarkdownToHTML(_:)` (lines 94-128) -- replaced by chunked API
- `processMermaidBlocks(_:)` (lines 130-155) -- mermaid detection in C
- `decodeHTMLEntities(_:)` (lines 157-164) -- no longer needed
- `encodeHTMLEntities(_:)` (lines 166-179) -- handled by C houdini
- `chunkHTML(_:)` (lines 181-224) -- chunking in C callback

**Static properties to REMOVE:**
- `mermaidRegex` (lines 37-39)
- `blockTagRegex` (lines 40-42)

---

### `MDViewerTests/MarkdownRendererTests.swift` (test, request-response)

**Analog:** `MDViewerTests/MarkdownRendererTests.swift` (current file)

**Test structure pattern** (lines 1-4):
```swift
import XCTest
@testable import MDViewer

final class MarkdownRendererTests: XCTestCase {
```

**Public API test pattern** (lines 6-13):
```swift
func testBasicMarkdownRendersToHTML() {
    let renderer = MarkdownRenderer()
    let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
    let joined = chunks.joined()
    XCTAssertTrue(joined.contains("<h1>"))
    XCTAssertTrue(joined.contains("Hello"))
    XCTAssertTrue(joined.contains("<p>World</p>"))
}
```

**Mermaid placeholder test pattern** (lines 28-41):
```swift
func testMermaidBlockBecomesPlaceholder() {
    let renderer = MarkdownRenderer()
    let md = """
    ```mermaid
    graph TD
        A --> B
    ```
    """
    let (chunks, hasMermaid) = renderer.render(markdown: md)
    let joined = chunks.joined()
    XCTAssertTrue(hasMermaid)
    XCTAssertTrue(joined.contains("mermaid-placeholder"))
    XCTAssertTrue(joined.contains("data-mermaid-source"))
    XCTAssertFalse(joined.contains("<pre><code class=\"language-mermaid\">"))
}
```

**Key insight:** The `render(markdown:)` API signature `(chunks: [String], hasMermaid: Bool)` and the `renderFullPage` APIs remain identical. All existing tests should pass with only the implementation change. Tests that check chunk splitting behavior at block boundaries (lines 100-121) should still pass since the C chunked API emits at top-level AST block boundaries.

---

### `MDViewer/AppDelegate.swift` (controller, request-response)

**Analog:** `MDViewer/AppDelegate.swift` (current file)

**Renderer usage pattern** (line 11):
```swift
private let renderer = MarkdownRenderer()
```

**Background render dispatch pattern** (lines 148-165):
```swift
let renderer = self.renderer
DispatchQueue.global(qos: .userInitiated).async {
    guard let result = renderer.renderFullPage(fileURL: url, template: tmpl) else {
        DispatchQueue.main.async {
            // ... error alert ...
        }
        return
    }
    DispatchQueue.main.async { [weak self] in
        self?.displayResult(result, for: url, paintState: paintState)
    }
}
```

**Expected change:** Minimal or none. `MarkdownRenderer` public API (`renderFullPage`, `render`) stays identical. The `RenderResult` struct is unchanged. AppDelegate should work without modification.

---

## Shared Patterns

### C Resource Cleanup (defer pattern)
**Source:** `MDViewer/MarkdownRenderer.swift` lines 100, 113, 125
**Apply to:** New `render()` implementation in MarkdownRenderer.swift
```swift
defer { cmark_parser_free(parser) }
defer { cmark_node_free(root) }
```

### OSSignposter Instrumentation
**Source:** `MDViewer/MarkdownRenderer.swift` lines 64-84
**Apply to:** New `renderFullPage(fileURL:template:)` implementation
```swift
let spID = renderingSignposter.makeSignpostID()
let readState = renderingSignposter.beginInterval("file-read", id: spID)
// ...
renderingSignposter.endInterval("file-read", readState)
```

### Weak Self in Closures
**Source:** `MDViewer/AppDelegate.swift` lines 30, 85, 116, 162, 186
**Apply to:** Any new closure-based code
```swift
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    // ...
}
```

### XcodeGen Target Excludes
**Source:** swift-cmark `Package.swift` lines 38-43 (src) and 51-53 (extensions)
**Apply to:** Both vendored static library targets in `project.yml`
```yaml
# src target
excludes:
  - "*.re"
  - "*.in"
  - CMakeLists.txt

# extensions target
excludes:
  - "*.re"
  - CMakeLists.txt
```

### Module Modulemap Settings
**Source:** `swift-cmark/src/include/module.modulemap`, `swift-cmark/extensions/include/module.modulemap`
**Apply to:** Both vendored targets in `project.yml`
```yaml
MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/src/include/module.modulemap
# and
MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/extensions/include/module.modulemap
```

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `Vendor/cmark-gfm/` (directory) | vendored-lib | N/A | New directory; contents are a direct copy from `/Users/mit/Documents/GitHub/swift-cmark/` src/ and extensions/ directories. No analog in project -- this is a file copy operation. |

## Metadata

**Analog search scope:** `MDViewer/`, `MDViewerTests/`, project root config files, `/Users/mit/Documents/GitHub/swift-cmark/`
**Files scanned:** 12 source files read, 3 config files read
**Pattern extraction date:** 2026-04-16
