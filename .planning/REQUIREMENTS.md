# Requirements: MDViewer v2.1 — Deep Optimization

**Defined:** 2026-04-16
**Core Value:** Open a markdown file and see beautifully rendered content instantly

## v2.1 Requirements

### Vendored cmark

- [x] **CMARK-01**: App uses a vendored copy of swift-cmark built as part of the Xcode project (no SPM dependency)
- [x] **CMARK-02**: Vendored cmark exposes a chunked HTML callback API that emits ≤64KB blocks at top-level AST boundaries
- [x] **CMARK-03**: Mermaid code blocks are detected in the C renderer (info string check) and emitted as placeholder divs
- [ ] **CMARK-04**: MarkdownRenderer uses the chunked API directly, eliminating regex-based HTML chunking and mermaid regex scan
- [ ] **CMARK-05**: Cached cmark extension list reused across renders (no per-render cmark_find_syntax_extension lookups)
- [ ] **CMARK-06**: Entity encoding uses append(contentsOf:) with correct capacity reservation

### WKWebView Pool

- [ ] **POOL-01**: App maintains a pool of 2 pre-warmed WKWebView instances ready for immediate use
- [ ] **POOL-02**: Pool replenishes asynchronously after a view is acquired
- [ ] **POOL-03**: Pool handles WebContent process termination (recreates crashed views)

### Streaming Pipeline

- [ ] **STRM-01**: First HTML chunk is delivered to WKWebView while remaining chunks are still being rendered from the AST
- [ ] **STRM-02**: Template concatenation reuses buffers instead of creating new String allocations per render

### Native Rendering

- [ ] **NATV-01**: Files without mermaid blocks or GFM tables render via NSTextView instead of WKWebView
- [ ] **NATV-02**: NSTextView backend walks the cmark AST directly to build NSAttributedString (no HTML intermediate)
- [ ] **NATV-03**: Native rendering uses the same Latin Modern Roman typography as the WKWebView path
- [ ] **NATV-04**: User can toggle between native and web rendering if visual differences arise

### Performance Validation

- [ ] **PERF-01**: Warm launch to first visible content is under 150ms for WKWebView path (measured via OSSignposter)
- [ ] **PERF-02**: Warm launch to first visible content is under 100ms for NSTextView path (measured via OSSignposter)
- [ ] **PERF-03**: 2nd+ file open is under 100ms with WKWebView pool active

## v2.0 Requirements (Validated)

### Memory Correctness

- [x] **MEM-01**: WKUserContentController retain cycle fixed — v2.0 Phase 1
- [x] **MEM-02**: File reading uses mappedIfSafe — v2.0 Phase 2
- [x] **MEM-03**: Mermaid.js loaded via script-src — v2.0 Phase 4

### Rendering Pipeline

- [x] **RENDER-01**: True N-chunk progressive rendering — v2.0 Phase 2
- [x] **RENDER-02**: callAsyncJavaScript with typed arguments — v2.0 Phase 2

### Launch Speed

- [x] **LAUNCH-01**: OSSignposter instrumentation — v2.0 Phase 1
- [x] **LAUNCH-02**: WKWebView pre-warm — v2.0 Phase 3

### Window Management

- [x] **WIN-01**: Window position persistence — v2.0 Phase 5
- [x] **WIN-02**: Window cascading — v2.0 Phase 5

## Out of Scope

| Feature | Reason |
|---------|--------|
| Swift async/await migration | WKWebView main-actor requirements make it a correctness risk |
| Zero-copy C-to-JS bridge | Research showed <0.1ms cost; IPC boundary is the real bottleneck |
| Incremental cmark parsing | cmark_parser_finish() required before AST access; streaming must be post-parse |
| Dark mode | Conflicts with LaTeX aesthetic |
| File editing | Viewer, not editor |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CMARK-01 | Phase 6 | Complete |
| CMARK-02 | Phase 6 | Complete |
| CMARK-03 | Phase 6 | Complete |
| CMARK-04 | Phase 6 | Pending |
| CMARK-05 | Phase 6 | Pending |
| CMARK-06 | Phase 6 | Pending |
| POOL-01 | Phase 7 | Pending |
| POOL-02 | Phase 7 | Pending |
| POOL-03 | Phase 7 | Pending |
| STRM-01 | Phase 8 | Pending |
| STRM-02 | Phase 8 | Pending |
| NATV-01 | Phase 9 | Pending |
| NATV-02 | Phase 9 | Pending |
| NATV-03 | Phase 9 | Pending |
| NATV-04 | Phase 9 | Pending |
| PERF-01 | Phase 8 | Pending |
| PERF-02 | Phase 9 | Pending |
| PERF-03 | Phase 7 | Pending |

**Coverage:**
- v2.1 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

---
*Requirements defined: 2026-04-16*
*Last updated: 2026-04-16 after roadmap creation*
