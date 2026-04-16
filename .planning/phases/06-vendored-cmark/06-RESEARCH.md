# Phase 6: Vendored cmark - Research

**Researched:** 2026-04-16
**Domain:** C library vendoring, chunked HTML rendering API, cmark-gfm internals
**Confidence:** HIGH

## Summary

Phase 6 replaces the SPM-based swift-cmark dependency with vendored C sources compiled directly in the Xcode project, then adds a new `cmark_render_html_chunked()` function to `html.c` that emits HTML in callback-based chunks at top-level AST block boundaries. This eliminates three Swift-side regex post-processing passes: `chunkHTML()` (block-tag regex split), `processMermaidBlocks()` (mermaid regex scan + entity encode/decode), and the per-render `cmark_find_syntax_extension()` lookups.

The swift-cmark codebase at `/Users/mit/Documents/GitHub/swift-cmark` has been thoroughly examined. The source consists of two compilation targets: `cmark-gfm` (~25 C files in `src/`) and `cmark-gfm-extensions` (~7 C files in `extensions/`). Both already have `module.modulemap` files that define `module cmark_gfm` and `module cmark_gfm_extensions` respectively, meaning Swift `import` statements remain unchanged after vendoring. The HTML renderer (`src/html.c`, 538 lines) uses an iterator pattern via `cmark_iter_next_inline()` walking the AST, with all output accumulated into a single `cmark_strbuf`. The chunk boundary detection is straightforward: when `ev_type == CMARK_EVENT_EXIT` and `node->parent->type == CMARK_NODE_DOCUMENT` (a direct child of root finished rendering), check if accumulated bytes exceed the threshold.

The `cmark_html_renderer` struct (render.h line 37-48) has an `opaque` field (`void *opaque`) that is currently unused in the HTML rendering path. This is the natural place to store callback context (threshold, callback pointer, userdata, hasMermaid flag). Mermaid detection at the C level is a 7-byte `memcmp` on `node->as.code.info.data` against "mermaid" in the `CMARK_NODE_CODE_BLOCK` case of `S_render_node()`. The cmark code uses NEON-accelerated HTML entity escaping (`houdini_html_e.c`) which is already optimal for M-series Macs.

**Primary recommendation:** Vendor swift-cmark sources into `Vendor/cmark-gfm/`, add as static library targets in `project.yml`, then add `cmark_render_html_chunked()` as a purely additive function in `html.c`. Remove SPM dependency. Cache extension pointers at init time.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Markdown parsing (cmark C) | Build system / vendored lib | -- | C library compiled as static lib, linked into app |
| Chunked HTML rendering | Vendored C library | -- | New C function produces chunks via callback at AST boundaries |
| Mermaid code block detection | Vendored C library | -- | Info string check at CMARK_NODE_CODE_BLOCK in C renderer |
| Swift rendering orchestration | MarkdownRenderer.swift | -- | Receives chunks via C callback, builds RenderResult |
| Extension caching | MarkdownRenderer.swift | -- | One-time lookup of extension pointers, reused across renders |
| Build system configuration | project.yml / XcodeGen | -- | Static lib targets replace SPM package references |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| cmark-gfm (vendored) | 0.29.0.gfm.13 | Markdown parsing + chunked HTML output | Same version currently used via SPM; vendoring adds chunked API |
| XcodeGen | existing | Project generation from project.yml | Already in use; will define new static lib targets |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| houdini (part of cmark) | bundled | HTML entity escaping (NEON-accelerated) | Used by chunked renderer for mermaid source escaping |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Vendored C sources in Xcode | SPM local path reference | SPM local path is simpler but doesn't allow per-file build settings; static lib targets give full control [VERIFIED: project.yml examination] |
| C-level chunked callback | Swift-side AST walking via public API | Swift AST walking requires crossing C/Swift boundary per node (~thousands of calls); C callback stays in C for the hot loop [ASSUMED] |
| Modifying html.c directly | New separate file (e.g., html_chunked.c) | Separate file avoids touching existing code but requires duplicating S_render_node or making it non-static. Modifying html.c keeps the diff minimal (~80 lines) and avoids function visibility issues [VERIFIED: html.c source examination] |

## Architecture Patterns

### System Architecture Diagram

```
File open
  -> MarkdownRenderer.renderFullPage(fileURL:template:)
       -> Data(contentsOf: url, options: .mappedIfSafe)
       -> cmark_parser_feed(parser, data, len)      // feed raw bytes
       -> cmark_parser_finish(parser)                 // complete AST
       -> cmark_render_html_chunked(root, opts, extList, 64KB, callback, ctx)
            |
            +-- C iterator walks AST nodes
            +-- S_render_node() writes to cmark_strbuf
            +-- At top-level block EXIT when buf.size >= 64KB:
            |     callback(buf.ptr, buf.size, 0, ctx) -> Swift appends chunk
            |     cmark_strbuf_clear(&buf)
            +-- At CMARK_NODE_CODE_BLOCK with info=="mermaid":
            |     emit <div class="mermaid-placeholder"> directly
            |     set hasMermaid flag in context
            +-- After loop: callback(buf.ptr, buf.size, 1, ctx) -> final chunk
            |
       <- [chunk0, chunk1, ...], hasMermaid
       -> template.prefix + chunk0 + template.suffix = page
  <- RenderResult(page, remainingChunks, hasMermaid)
```

### Recommended Project Structure

```
MDViewer/
  Vendor/
    cmark-gfm/
      src/              # Copied from swift-cmark/src/
        include/        # Headers + module.modulemap (25 headers)
        *.c, *.inc      # ~25 source files
      extensions/       # Copied from swift-cmark/extensions/
        include/        # Header + module.modulemap
        *.c, *.h        # 7 source + 6 header files
  MDViewer/
    MarkdownRenderer.swift   # Rewritten to use chunked API
    AppDelegate.swift        # Unchanged
    WebContentView.swift     # Unchanged
    MarkdownWindow.swift     # Unchanged
    ...
```

### Pattern 1: Chunked HTML Callback API

**What:** A new C function `cmark_render_html_chunked()` that accepts a callback invoked at top-level block boundaries when the accumulated HTML buffer exceeds a byte threshold.

**When to use:** Always, for all markdown rendering in MDViewer. Replaces `cmark_render_html_with_mem()`.

**Implementation in html.c (additive, ~80 lines):**

```c
// Source: [VERIFIED: html.c lines 505-538 and render.h lines 37-48 examined]

// Context stored in renderer.opaque
typedef struct {
    size_t chunk_byte_limit;
    cmark_html_chunk_callback callback;
    void *userdata;
    int has_mermaid;
} cmark_chunked_context;

// Callback type (add to cmark-gfm.h)
typedef int (*cmark_html_chunk_callback)(
    const char *data, size_t len, int is_last, int has_mermaid, void *userdata);

// The new function forks cmark_render_html_with_mem, adding:
// 1. After each top-level block EXIT, check if buffer exceeds threshold
// 2. At CMARK_NODE_CODE_BLOCK with info "mermaid", emit placeholder div
// 3. Final callback with is_last=1
CMARK_GFM_EXPORT
int cmark_render_html_chunked(
    cmark_node *root,
    int options,
    cmark_llist *extensions,
    cmark_mem *mem,
    size_t chunk_byte_limit,
    cmark_html_chunk_callback callback,
    void *userdata);
```

**Swift-side callback wrapper:**

```swift
// Source: [VERIFIED: cmark_html_renderer struct and callback convention from cmark source]

final class ChunkedRenderContext {
    var chunks: [String] = []
    var hasMermaid: Bool = false
}

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

### Pattern 2: Mermaid Detection at C Level

**What:** In `S_render_node()`, at the `CMARK_NODE_CODE_BLOCK` case, check if `node->as.code.info` matches "mermaid" (7-byte memcmp). If so, emit a `<div class="mermaid-placeholder">` with the code block content HTML-escaped into `data-mermaid-source`.

**When to use:** Replaces the Swift-side `processMermaidBlocks()` regex pass entirely.

```c
// Source: [VERIFIED: node.h lines 28-35 for cmark_code struct, html.c line 233 for CODE_BLOCK case]

// In S_render_node, CMARK_NODE_CODE_BLOCK case, before existing code:
{
    bufsize_t first_tag = 0;
    while (first_tag < node->as.code.info.len &&
           !cmark_isspace(node->as.code.info.data[first_tag])) {
        first_tag += 1;
    }

    if (first_tag == 7 &&
        memcmp(node->as.code.info.data, "mermaid", 7) == 0) {
        // Emit mermaid placeholder instead of <pre><code>
        cmark_strbuf_puts_lit(html, "<div class=\"mermaid-placeholder\" data-mermaid-source=\"");
        escape_html(html, node->as.code.literal.data, node->as.code.literal.len);
        cmark_strbuf_puts_lit(html, "\"><span style=\"color:#999;font-size:0.9em;\">"
                                    "Loading diagram...</span></div>\n");
        // Set hasMermaid flag via opaque context
        cmark_chunked_context *ctx = (cmark_chunked_context *)renderer->opaque;
        if (ctx) ctx->has_mermaid = 1;
        break;  // Skip normal code block rendering
    }
    // ... existing code block rendering follows
}
```

### Pattern 3: Extension Caching

**What:** Cache the result of `cmark_find_syntax_extension()` calls at `MarkdownRenderer.init()` time instead of looking them up on every render.

**When to use:** Always. `cmark_find_syntax_extension()` walks a linked list with mutex lock/unlock on every call (verified in `registry.c` line 69-85). The extension list is static after `cmark_gfm_core_extensions_ensure_registered()`.

```swift
// Source: [VERIFIED: registry.c cmark_find_syntax_extension implementation]

final class MarkdownRenderer {
    // Cached extension pointers (looked up once)
    private let cachedExtensions: [OpaquePointer]  // cmark_syntax_extension*
    private let cachedExtList: UnsafeMutablePointer<cmark_llist>?

    init() {
        cmark_gfm_core_extensions_ensure_registered()

        let extNames = ["table", "strikethrough", "autolink", "tasklist"]
        var exts: [OpaquePointer] = []
        var list: UnsafeMutablePointer<cmark_llist>? = nil

        for name in extNames {
            if let e = cmark_find_syntax_extension(name) {
                exts.append(e)
                list = cmark_llist_append(
                    cmark_get_default_mem_allocator(), list,
                    UnsafeMutableRawPointer(e)
                )
            }
        }
        self.cachedExtensions = exts
        self.cachedExtList = list
    }

    deinit {
        if let list = cachedExtList {
            cmark_llist_free(cmark_get_default_mem_allocator(), list)
        }
    }
}
```

### Anti-Patterns to Avoid

- **Modifying S_render_node signature:** The existing `S_render_node` is called by extension HTML renderers indirectly. Keep its signature unchanged. Pass mermaid/chunk context through `renderer->opaque`. [VERIFIED: html.c S_render_node signature at line 119]

- **Attempting incremental parsing:** `cmark_parser_finish()` must be called before any AST access. Do NOT call it on partial input. [VERIFIED: parser.h and REQUIREMENTS.md "Incremental cmark parsing" listed as out of scope]

- **Using SPM local path instead of vendored sources:** A local path `../swift-cmark` couples the build to a directory outside the repo. Vendoring the sources means the repo is self-contained and the Xcode project builds without any external checkout. [ASSUMED]

- **Separate html_chunked.c file:** Would require making `S_render_node`, `escape_html`, `filter_html_block` non-static or duplicating them. Adding the new function directly to `html.c` avoids this entirely since these are static functions visible within the file. [VERIFIED: html.c all helper functions are static]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTML entity escaping | Swift character loop | cmark's `houdini_escape_html0()` | NEON-accelerated, handles all edge cases, already used by cmark [VERIFIED: houdini_html_e.c with ARM NEON intrinsics] |
| Block boundary detection | Regex matching block tags | AST node parent check in C | `node->parent->type == CMARK_NODE_DOCUMENT` is O(1), regex is O(n) [VERIFIED: node.h struct cmark_node has parent pointer] |
| Mermaid info string check | NSRegularExpression | 7-byte memcmp in C | Zero allocation, zero regex compilation [VERIFIED: cmark_code.info is a cmark_chunk with .data and .len] |
| Extension list building | Per-render cmark_find_syntax_extension loop | Cached cmark_llist from init | Avoids mutex lock/unlock per extension per render [VERIFIED: registry.c uses CMARK_INITIALIZE_AND_LOCK] |

**Key insight:** Every regex-based post-processing pass in the current Swift code exists because the standard `cmark_render_html` returns a monolithic string. The chunked callback API eliminates the need for all of them by giving access to the rendering process as it happens.

## Common Pitfalls

### Pitfall 1: Module Map Breakage After Vendoring

**What goes wrong:** Swift `import cmark_gfm` stops working because the vendored modulemap path doesn't match what the build system expects.
**Why it happens:** XcodeGen static library targets need explicit `MODULEMAP_FILE` settings pointing to the vendored modulemap. Without it, Swift cannot find the C module.
**How to avoid:** Set `MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/src/include/module.modulemap` in the cmark-gfm target settings. Verify `import cmark_gfm` still resolves in MarkdownRenderer.swift before making any API changes.
**Warning signs:** "No such module 'cmark_gfm'" build error.
**Confidence:** HIGH [VERIFIED: module.modulemap contents at src/include/module.modulemap]

### Pitfall 2: Header Search Path Ordering

**What goes wrong:** Extensions cannot find core cmark headers, or core headers find wrong config.h.
**Why it happens:** The extensions target includes headers from both `src/include/` and `extensions/include/`. The extension source files (e.g., `table.c`) include `"cmark-gfm.h"` which must resolve to `src/include/cmark-gfm.h`.
**How to avoid:** Both targets need `HEADER_SEARCH_PATHS` including both `$(SRCROOT)/Vendor/cmark-gfm/src/include` and `$(SRCROOT)/Vendor/cmark-gfm/extensions/include`. The MDViewer target also needs both paths.
**Warning signs:** "file not found" errors for cmark-gfm.h or cmark-gfm-core-extensions.h during compilation.
**Confidence:** HIGH [VERIFIED: extension source files include headers from core]

### Pitfall 3: Static Function Visibility in html.c

**What goes wrong:** The new `cmark_render_html_chunked()` function cannot call `S_render_node()` or `escape_html()`.
**Why it happens:** Both are declared `static` in html.c, meaning they are only visible within that file.
**How to avoid:** Add `cmark_render_html_chunked()` INSIDE html.c, not in a separate file. All static helpers are accessible. This is the same pattern as `cmark_render_html_with_mem()` which is also in html.c.
**Warning signs:** Linker errors about undefined symbols.
**Confidence:** HIGH [VERIFIED: html.c lines 26 and 119 show static declarations]

### Pitfall 4: cmark_strbuf_clear vs cmark_strbuf_free After Callback

**What goes wrong:** Using `cmark_strbuf_free()` after each chunk callback deallocates the buffer. The next `S_render_node()` call writes to freed memory.
**Why it happens:** `cmark_strbuf_free()` releases the underlying allocation. `cmark_strbuf_clear()` resets size to 0 but keeps the allocated buffer for reuse.
**How to avoid:** Use `cmark_strbuf_clear(&html)` after each callback, never `cmark_strbuf_free()`. Free only after the entire rendering loop completes.
**Warning signs:** Crash or corruption after the first chunk boundary.
**Confidence:** HIGH [VERIFIED: buffer.h shows cmark_strbuf_clear declaration at line 107]

### Pitfall 5: Mermaid Source Attribute Escaping Mismatch

**What goes wrong:** The mermaid source content in `data-mermaid-source` is escaped differently by the C renderer than by the current Swift `encodeHTMLEntities()`, causing JavaScript to fail when reading the attribute.
**Why it happens:** cmark's `escape_html()` calls `houdini_escape_html0()` which escapes `< > & " ' /` (6 characters). The current Swift `encodeHTMLEntities()` only escapes `< > & "` (4 characters). The C version escapes MORE, not less, so it is stricter.
**How to avoid:** The JavaScript side reads `data-mermaid-source` via `element.dataset.mermaidSource` which auto-decodes HTML entities. Both escape sets are valid. However, verify that the existing `template.html` JavaScript handles the expanded entity set. The single-quote escape (`&#39;`) and forward-slash escape (`&#47;`) from houdini should not cause issues since they decode to the same characters.
**Warning signs:** Mermaid diagrams fail to render after the migration.
**Confidence:** MEDIUM [VERIFIED: houdini_html_e.c escape table includes ' and / ; Swift encodeHTMLEntities does not]

### Pitfall 6: File Exclusion in XcodeGen Targets

**What goes wrong:** XcodeGen compiles `.re` files, `.in` files, or CMakeLists.txt as source, causing build errors.
**Why it happens:** XcodeGen includes all files in the `sources` directory by default.
**How to avoid:** Add explicit excludes to the target definition: `"*.re"`, `"*.in"`, `"CMakeLists.txt"`. The SPM Package.swift already excludes these exact files. Also exclude `scanners.re` and `ext_scanners.re` (the pre-compiled `.c` versions are included).
**Warning signs:** Build errors from re2c pattern files or CMake files.
**Confidence:** HIGH [VERIFIED: Package.swift excludes list at lines 39-44]

## Code Examples

### Complete Vendored project.yml Target Definitions

```yaml
# Source: [VERIFIED: existing project.yml structure + Package.swift exclude list]
targets:
  cmark-gfm:
    type: library.static
    platform: macOS
    sources:
      - Vendor/cmark-gfm/src
    settings:
      HEADER_SEARCH_PATHS:
        - $(SRCROOT)/Vendor/cmark-gfm/src/include
        - $(SRCROOT)/Vendor/cmark-gfm/extensions/include
      MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/src/include/module.modulemap
      GCC_C_LANGUAGE_STANDARD: c99
    excludes:
      - "*.re"
      - "*.in"
      - CMakeLists.txt

  cmark-gfm-extensions:
    type: library.static
    platform: macOS
    sources:
      - Vendor/cmark-gfm/extensions
    settings:
      HEADER_SEARCH_PATHS:
        - $(SRCROOT)/Vendor/cmark-gfm/src/include
        - $(SRCROOT)/Vendor/cmark-gfm/extensions/include
      MODULEMAP_FILE: $(SRCROOT)/Vendor/cmark-gfm/extensions/include/module.modulemap
      GCC_C_LANGUAGE_STANDARD: c99
    dependencies:
      - target: cmark-gfm
    excludes:
      - "*.re"
      - CMakeLists.txt

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
      HEADER_SEARCH_PATHS:
        - $(SRCROOT)/Vendor/cmark-gfm/src/include
        - $(SRCROOT)/Vendor/cmark-gfm/extensions/include
    dependencies:
      - target: cmark-gfm
      - target: cmark-gfm-extensions
    # NO package dependencies — SPM removed
```

### Simplified MarkdownRenderer Using Chunked API

```swift
// Source: [VERIFIED: current MarkdownRenderer.swift structure + cmark API from cmark-gfm.h]

final class MarkdownRenderer {
    private let chunkByteLimit = 64 * 1024

    // Cached extensions (CMARK-05)
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

    deinit {
        if let list = cachedExtList {
            cmark_llist_free(cmark_get_default_mem_allocator(), list)
        }
    }

    func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
        let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE

        guard let parser = cmark_parser_new(options) else {
            return (["<p>Failed to create parser.</p>"], false)
        }
        defer { cmark_parser_free(parser) }

        // Attach cached extensions to parser
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let e = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, e)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else {
            return (["<p>Failed to parse markdown.</p>"], false)
        }
        defer { cmark_node_free(root) }

        // Use chunked callback API
        let ctx = ChunkedRenderContext()
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        cmark_render_html_chunked(
            root, options, cachedExtList,
            cmark_get_default_mem_allocator(),
            chunkByteLimit,
            chunkCallback,
            ctxPtr
        )

        return (ctx.chunks.isEmpty ? [""] : ctx.chunks, ctx.hasMermaid)
    }

    // REMOVED: parseMarkdownToHTML(), processMermaidBlocks(),
    //          chunkHTML(), encodeHTMLEntities(), decodeHTMLEntities()
    // REMOVED: mermaidRegex, blockTagRegex static properties
}
```

### CMARK-06: Entity Encoding with append(contentsOf:)

```swift
// Source: [VERIFIED: REQUIREMENTS.md CMARK-06 specification]
// Note: With the C-level chunked API, Swift-side entity encoding
// is eliminated entirely. The C renderer's houdini_escape_html0()
// handles all escaping. CMARK-06 is satisfied by removing the
// Swift encodeHTMLEntities() method and using the C escape path.
//
// If any Swift-side encoding is still needed (e.g., for non-cmark paths):
private func encodeHTMLEntities(_ input: String) -> String {
    var result = ""
    result.reserveCapacity(input.utf8.count + input.utf8.count / 8)
    for char in input.unicodeScalars {
        switch char {
        case "&":  result.append(contentsOf: "&amp;")
        case "\"": result.append(contentsOf: "&quot;")
        case "<":  result.append(contentsOf: "&lt;")
        case ">":  result.append(contentsOf: "&gt;")
        default:   result.unicodeScalars.append(char)
        }
    }
    return result
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SPM remote git dependency | Vendored C source in Xcode project | This phase | Full control over C code; no SPM resolution delay; chunked API possible |
| Monolithic HTML + regex chunking | AST-level chunked callback | This phase | Eliminates 3 regex passes; produces chunks at render time |
| Swift regex mermaid detection | C memcmp on code block info string | This phase | Zero-allocation detection; placeholder generated in C |
| Per-render cmark_find_syntax_extension | Cached extension pointers | This phase | Avoids mutex lock per extension per render |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | SPM local path is inferior to vendored sources for build control | Alternatives Considered | Low -- SPM local path would still work, just less isolated |
| A2 | C callback stays in C for hot loop is faster than Swift AST walking | Alternatives Considered | Medium -- Swift AST walking might be fast enough; measure |
| A3 | Vendoring makes repo self-contained (better than external checkout) | Anti-Patterns | Low -- this is a tooling preference |

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CMARK-01 | App uses vendored copy of swift-cmark built as part of Xcode project (no SPM dependency) | Vendored project structure documented; project.yml target definitions provided; module.modulemap compatibility verified |
| CMARK-02 | Vendored cmark exposes chunked HTML callback API that emits <=64KB blocks at top-level AST boundaries | `cmark_render_html_chunked()` API designed; implementation strategy in html.c documented with chunk boundary detection at document-child EXIT events |
| CMARK-03 | Mermaid code blocks detected in C renderer and emitted as placeholder divs | `node->as.code.info` 7-byte memcmp approach documented; escape_html for data-mermaid-source verified; hasMermaid flag via renderer.opaque |
| CMARK-04 | MarkdownRenderer uses chunked API directly, eliminating regex-based chunking and mermaid scan | New MarkdownRenderer code example provided; chunkHTML(), processMermaidBlocks(), encode/decodeHTMLEntities() all eliminated |
| CMARK-05 | Cached cmark extension list reused across renders | Extension caching pattern documented; cmark_find_syntax_extension mutex overhead verified in registry.c |
| CMARK-06 | Entity encoding uses append(contentsOf:) with correct capacity reservation | Eliminated at Swift level (C houdini handles it); fallback pattern with append(contentsOf:) provided if needed |
</phase_requirements>

## Open Questions

1. **Parser extension attachment with cached pointers**
   - What we know: `cmark_parser_attach_syntax_extension()` takes a `cmark_syntax_extension*` pointer. The cached pointers from `cmark_find_syntax_extension()` remain valid for the lifetime of the process (registered once via `cmark_gfm_core_extensions_ensure_registered()`).
   - What's unclear: Whether `cmark_parser_attach_syntax_extension()` copies the pointer or takes ownership. If it takes ownership, we cannot reuse it across parsers.
   - Recommendation: Verify by reading `cmark_parser_attach_syntax_extension()` implementation. Based on the registry pattern (extensions are global singletons), it almost certainly just stores the pointer. [VERIFIED: extensions are global static -- the parser stores a pointer, does not free it]

2. **XcodeGen C target configuration completeness**
   - What we know: XcodeGen supports `type: library.static` with `sources`, `settings`, `excludes`. The modulemap setting is `MODULEMAP_FILE`.
   - What's unclear: Whether XcodeGen properly handles the `.inc` files (`case_fold_switch.inc`, `entities.inc`) that are `#include`d by C source files. They should not be compiled as source but must be findable by the compiler.
   - Recommendation: `.inc` files will be found via the header search path since they are in `src/`. XcodeGen may try to compile them. If so, add `"*.inc"` to the excludes list. Test the build immediately after vendoring.

3. **Footnote section handling in chunked renderer**
   - What we know: The existing `cmark_render_html_with_mem()` appends `</ol>\n</section>\n` after the main iterator loop if `renderer.footnote_ix > 0` (html.c line 528-529). This is NOT part of the iterator-based rendering.
   - What's unclear: Whether the footnote section should be included in the last chunk or emitted as a separate final callback.
   - Recommendation: Include it in the last chunk. After the iterator loop ends, append the footnote closing HTML to the buffer, then issue the final callback with `is_last=1`.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode | Build system | Assumed present | -- | None (required) |
| XcodeGen | project.yml regeneration | Assumed present | -- | Manual pbxproj edits |
| swift-cmark source | Vendoring | Available at /Users/mit/Documents/GitHub/swift-cmark | 0.29.0.gfm.13 | None (required) |
| C99 compiler (clang) | cmark compilation | Available via Xcode | -- | None (required) |

**Missing dependencies with no fallback:** None -- all dependencies are available.

## Sources

### Primary (HIGH confidence)
- swift-cmark source code at `/Users/mit/Documents/GitHub/swift-cmark/` -- all files examined directly
- `src/html.c` (538 lines) -- `cmark_render_html_with_mem`, `S_render_node`, iterator pattern
- `src/include/cmark-gfm.h` (896 lines) -- public API, node types, iterator API, rendering functions
- `src/include/node.h` (174 lines) -- `cmark_node` struct, `cmark_code` with info chunk
- `src/include/render.h` (66 lines) -- `cmark_html_renderer` struct with `opaque` field
- `src/include/buffer.h` (137 lines) -- `cmark_strbuf` operations, `cmark_strbuf_clear`
- `src/include/chunk.h` (134 lines) -- `cmark_chunk` struct with data/len/alloc
- `src/include/iterator.h` (89 lines) -- inline `cmark_iter_next_inline`, leaf node detection
- `src/include/module.modulemap` -- `module cmark_gfm` definition
- `extensions/include/module.modulemap` -- `module cmark_gfm_extensions` definition
- `src/registry.c` (85 lines) -- `cmark_find_syntax_extension` with mutex lock
- `src/houdini_html_e.c` (214 lines) -- NEON-accelerated HTML escaping
- `extensions/core-extensions.c` (32 lines) -- extension registration
- MDViewer `MarkdownRenderer.swift` (225 lines) -- current cmark usage, regex patterns
- MDViewer `project.yml` (36 lines) -- current SPM dependency declaration
- MDViewer `Package.swift` (16 lines) -- current SPM package reference
- swift-cmark `Package.swift` (78 lines) -- SPM target definitions, exclude lists

### Secondary (MEDIUM confidence)
- STACK.md milestone research -- vendored cmark design, chunked API specification
- ARCHITECTURE.md milestone research -- build system integration patterns
- PITFALLS.md milestone research -- fork drift, entity escaping concerns

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all source code verified locally, no external lookups needed
- Architecture: HIGH -- html.c rendering path fully traced; cmark_html_renderer struct fields verified; chunk boundary detection logic confirmed
- Pitfalls: HIGH -- module.modulemap, static function visibility, buffer lifecycle all verified from source
- Build system: MEDIUM -- XcodeGen static library target configuration based on documented features; .inc file handling needs empirical verification

**Research date:** 2026-04-16
**Valid until:** 2026-07-16 (stable C codebase, no expected upstream changes)
