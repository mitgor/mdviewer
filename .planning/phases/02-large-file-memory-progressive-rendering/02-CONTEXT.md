# Phase 2: Large File Memory & Progressive Rendering - Context

**Gathered:** 2026-04-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Memory-efficient file reading and true N-chunk progressive rendering for 10MB+ markdown files. Users can open large files without heap spikes, and content appears progressively in multiple visible stages. No new features — this phase optimizes the existing rendering pipeline.

</domain>

<decisions>
## Implementation Decisions

### Memory-Mapped File Reading
- **D-01:** Use `Data(contentsOf:options:.mappedIfSafe)` then decode to `String` — avoids loading the entire file into heap memory. This directly satisfies MEM-02.
- **D-02:** Keep the existing `renderFullPage(fileURL:template:)` signature — the change is internal to the file read step only.

### Chunk Sizing & Splitting
- **D-03:** Split HTML at block-tag boundaries (p, h1-h6, div, pre, blockquote, table, ul, ol, hr, li) with a target of ≤64KB per chunk. This replaces the current 2-chunk approach with true N-chunk rendering (RENDER-01).
- **D-04:** The current `chunkThreshold = 50` (block tags) approach should be replaced with byte-size-based splitting. Walk block-tag positions and accumulate until the 64KB threshold is reached, then split.

### Chunk Injection
- **D-05:** Replace `evaluateJavaScript` with `callAsyncJavaScript` using a typed `html` argument for each chunk. This eliminates the string interpolation injection risk (RENDER-02) and removes the need for the manual character escaping loop.
- **D-06:** Inject chunks one at a time with 16ms staggering (preserve current timing), not all at once in a single JS call.

### Progressive Rendering UX
- **D-07:** Chunks appear seamlessly — no loading spinners or visual indicators between chunks. Content simply grows as chunks are appended (matches current behavior).
- **D-08:** First screen of content appears before remaining chunks finish loading (existing behavior preserved via firstPaint callback).

### Claude's Discretion
- Whether to keep `chunkHTML()` as a method on `MarkdownRenderer` or extract it — Claude can decide based on code organization.
- The exact staggering timing (16ms vs other values) for chunk injection — preserve 16ms unless profiling shows a different value is better.
- Whether `renderFullPage(markdown:template:)` (the non-file overload used by tests) also gets N-chunk splitting or stays as-is.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — MEM-02, RENDER-01, RENDER-02 definitions and acceptance criteria

### Architecture
- `.planning/codebase/ARCHITECTURE.md` — Full data flow from file open to chunk injection
- `.planning/codebase/CONCERNS.md` — Known issues with current chunking approach

### Phase 1 Instrumentation
- `.planning/phases/01-correctness-measurement-baseline/01-01-SUMMARY.md` — What Phase 1 changed in these same files
- `.planning/phases/01-correctness-measurement-baseline/01-RESEARCH.md` — Research on WKWebView patterns (relevant for callAsyncJavaScript)

### Source Files (primary modification targets)
- `MDViewer/MarkdownRenderer.swift` — Current file reading and chunk splitting logic
- `MDViewer/WebContentView.swift` — Current chunk injection via evaluateJavaScript
- `MDViewer/AppDelegate.swift` — openFile dispatch and displayResult coordination

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `SplitTemplate` struct: Pre-split template with prefix/suffix — works with any chunk content, no changes needed
- `RenderResult` struct: Carries `page`, `remainingChunks`, `hasMermaid` — may need update if chunk count changes significantly
- `appendChunk(html)` JS function in template.html: Already handles appending HTML to the document body
- `renderingSignposter` / `OSSignposter` intervals: Already instrument file-read, parse, chunk-split, chunk-inject stages

### Established Patterns
- Background rendering on `DispatchQueue.global(qos: .userInitiated)`, all UI on main thread
- `[weak self]` in all closures that capture self
- `guard let` early returns for failure cases
- `defer` for C resource cleanup (cmark)
- `#if DEBUG` for development-only logging

### Integration Points
- `MarkdownRenderer.renderFullPage(fileURL:template:)` — change file reading and chunk splitting here
- `WebContentView.injectRemainingChunks()` — replace evaluateJavaScript with callAsyncJavaScript here
- `WebContentView.loadContent(page:remainingChunks:hasMermaid:)` — may need to accept more chunks
- OSSignposter intervals already wrap each stage — new implementation should preserve these

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. Key constraint: the existing rendering pipeline structure (parse → chunk → first paint → inject remaining) must be preserved.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 02-large-file-memory-progressive-rendering*
*Context gathered: 2026-04-06*
