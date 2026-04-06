# Phase 2: Large File Memory & Progressive Rendering - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-06
**Phase:** 02-large-file-memory-progressive-rendering
**Areas discussed:** Memory-mapped read approach, Chunk sizing strategy, Chunk injection API, Progressive rendering visibility
**Mode:** --auto (all decisions auto-selected with recommended defaults)

---

## Memory-Mapped Read Approach

| Option | Description | Selected |
|--------|-------------|----------|
| Data(contentsOf:options:.mappedIfSafe) | Memory-map the file, decode to String — avoids full heap allocation | ✓ |
| DispatchIO streaming | Stream file in chunks via GCD — more complex, deferred to v2/SCALE-01 | |
| Keep String(contentsOf:) | Current approach — simple but spikes heap for large files | |

**User's choice:** [auto] Data(contentsOf:options:.mappedIfSafe) (recommended default)
**Notes:** Directly satisfies MEM-02. Streaming via DispatchIO is out of scope (SCALE-01).

---

## Chunk Sizing Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Block-tag boundaries ≤64KB | Walk block tags, accumulate to 64KB threshold, split | ✓ |
| Fixed byte-count splits | Split at arbitrary byte positions — may break HTML tags | |
| AST-level chunking | Walk cmark AST nodes — deferred to SCALE-02 | |

**User's choice:** [auto] Block-tag boundaries ≤64KB (recommended default)
**Notes:** Preserves valid HTML structure at split points. AST-level chunking deferred to v2.

---

## Chunk Injection API

| Option | Description | Selected |
|--------|-------------|----------|
| callAsyncJavaScript with typed args | Pass HTML as typed argument, no string escaping needed | ✓ |
| evaluateJavaScript with improved escaping | Keep current API, fix escaping | |
| WKURLSchemeHandler | Serve chunks via custom URL scheme — over-engineered for this | |

**User's choice:** [auto] callAsyncJavaScript with typed args (recommended default)
**Notes:** Directly satisfies RENDER-02. Eliminates injection risk from string interpolation.

---

## Progressive Rendering Visibility

| Option | Description | Selected |
|--------|-------------|----------|
| Seamless (no indicators) | Content grows as chunks append, no spinners or placeholders | ✓ |
| Loading skeleton | Show content skeleton that fills in as chunks arrive | |
| Progress bar | Show a thin progress bar at top during chunk loading | |

**User's choice:** [auto] Seamless (recommended default)
**Notes:** Matches current UX — content simply appears progressively.

---

## Claude's Discretion

- Code organization of chunkHTML (keep on MarkdownRenderer or extract)
- Chunk injection staggering timing (16ms default)
- Whether test-facing renderFullPage(markdown:) overload also gets N-chunk splitting

## Deferred Ideas

None — discussion stayed within phase scope.
