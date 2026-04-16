---
phase: 06-vendored-cmark
plan: 02
subsystem: rendering
tags: [cmark-gfm, chunked-html, mermaid, c-api, callback]

# Dependency graph
requires:
  - phase: 06-01
    provides: Vendored cmark-gfm C sources with static library targets
provides:
  - cmark_render_html_chunked() C API for chunked HTML callback rendering
  - C-level mermaid code block detection emitting placeholder divs
  - cmark_html_chunk_callback typedef for Swift interop
affects: [06-03]

# Tech tracking
tech-stack:
  added: []
  patterns: [chunked callback API pattern for C-to-Swift HTML streaming, renderer opaque pointer for context passing]

key-files:
  created: []
  modified:
    - Vendor/cmark-gfm/src/include/cmark-gfm.h (callback typedef + function declaration)
    - Vendor/cmark-gfm/src/html.c (chunked context struct, mermaid detection, chunked renderer)

key-decisions:
  - "Mermaid detection uses opaque pointer NULL check so non-chunked render path is unaffected"
  - "Chunk emission at top-level block EXIT boundaries (parent == DOCUMENT node)"
  - "cmark_chunked_context typedef placed before S_render_node for forward visibility"

patterns-established:
  - "Renderer opaque pointer pattern: store callback context in renderer->opaque, NULL-check before cast"
  - "Mermaid placeholder: <div class='mermaid-placeholder' data-mermaid-source='...'> emitted at C level"

requirements-completed: [CMARK-02, CMARK-03]

# Metrics
duration: 2min
completed: 2026-04-16
---

# Phase 06 Plan 02: Chunked HTML API + Mermaid Detection Summary

**Added cmark_render_html_chunked() callback API and C-level mermaid code block detection to vendored cmark-gfm**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-16T08:13:52Z
- **Completed:** 2026-04-16T08:15:40Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Declared cmark_html_chunk_callback typedef and cmark_render_html_chunked() in public header
- Implemented chunked HTML renderer that emits chunks at top-level AST block boundaries when buffer exceeds threshold
- Added mermaid code block detection in S_render_node that emits placeholder divs instead of pre/code blocks
- Existing non-chunked render path completely unaffected (NULL check on opaque pointer)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add chunked callback type and declaration to cmark-gfm.h** - `080b9a3` (feat)
2. **Task 2: Implement cmark_render_html_chunked with mermaid detection in html.c** - `14b2a30` (feat)

## Files Created/Modified
- `Vendor/cmark-gfm/src/include/cmark-gfm.h` - Added cmark_html_chunk_callback typedef and cmark_render_html_chunked declaration
- `Vendor/cmark-gfm/src/html.c` - Added cmark_chunked_context struct, mermaid detection in CODE_BLOCK case, and cmark_render_html_chunked function

## Decisions Made
- **Opaque pointer NULL check for mermaid flag:** The mermaid detection in S_render_node checks `renderer->opaque != NULL` before casting to `cmark_chunked_context*`. This ensures the existing `cmark_render_html_with_mem` (which sets opaque=NULL) is completely unaffected -- mermaid blocks still render as normal pre/code in the non-chunked path.
- **Top-level block EXIT for chunk boundaries:** Chunks are emitted when the iterator exits a direct child of the DOCUMENT node and the buffer exceeds the threshold. This produces clean chunk boundaries at paragraph/heading/list/codeblock boundaries.
- **Forward typedef placement:** The cmark_chunked_context typedef is placed near the top of html.c (after escape_html, before S_render_node) so it is visible to the mermaid detection code in S_render_node.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed doc comment HTML warnings in cmark-gfm.h**
- **Found during:** Task 2 (build verification)
- **Issue:** Doc comment for cmark_render_html_chunked contained literal HTML tags (`<div>`, `<pre>`, `<code>`) causing -Wdocumentation-html warnings
- **Fix:** Replaced literal HTML with `\c` Doxygen markup and plain text description
- **Files modified:** Vendor/cmark-gfm/src/include/cmark-gfm.h
- **Verification:** Rebuild shows no new warnings
- **Committed in:** 14b2a30 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Trivial doc comment fix. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Chunked C API ready for Swift integration in Plan 03
- Swift layer can call cmark_render_html_chunked with a callback closure
- Mermaid detection eliminates need for regex post-processing in MarkdownRenderer
- hasMermaid flag available in callback parameters

---
*Phase: 06-vendored-cmark*
*Completed: 2026-04-16*
