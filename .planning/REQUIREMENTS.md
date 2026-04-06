# Requirements: MDViewer v2.0 — Speed & Memory

**Defined:** 2026-04-06
**Core Value:** Open a markdown file and see beautifully rendered content instantly

## v1 Requirements

### Memory Correctness

- [x] **MEM-01**: WKUserContentController retain cycle fixed — closing a window releases all WKWebView memory
- [ ] **MEM-02**: File reading uses `Data(contentsOf:options:.mappedIfSafe)` — 10MB+ files don't spike heap
- [ ] **MEM-03**: Mermaid.js loaded via `<script src>` in template, not 3MB `evaluateJavaScript` bridge call

### Rendering Pipeline

- [ ] **RENDER-01**: True N-chunk progressive rendering — HTML split at block boundaries into chunks ≤64KB
- [ ] **RENDER-02**: Chunk injection uses `callAsyncJavaScript` with typed arguments instead of string interpolation

### Launch Speed

- [x] **LAUNCH-01**: `os_signpost` instrumentation added to measure each pipeline phase
- [ ] **LAUNCH-02**: WKWebView pre-warmed at app launch — reused for first file open
- [ ] **LAUNCH-03**: Sub-100ms warm launch to first visible content on Apple Silicon

### Window Management

- [ ] **WIN-01**: Window position and size persisted across app launches via `setFrameAutosaveName`
- [ ] **WIN-02**: Multiple windows cascade properly instead of stacking at same position

## v2 Requirements

### Extreme Scale

- **SCALE-01**: Streaming parse via `DispatchIO` for 50MB+ files
- **SCALE-02**: AST-level chunking (walk cmark AST nodes instead of splitting HTML strings)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Swift async/await migration | WKWebView main-actor requirements make it a correctness risk |
| Custom cmark renderer | Only needed for 50MB+ files, deferred to v3 |
| Dynamic framework reduction | Unclear ROI without profiling data |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| MEM-01 | Phase 1 | Complete |
| MEM-02 | Phase 2 | Pending |
| MEM-03 | Phase 4 | Pending |
| RENDER-01 | Phase 2 | Pending |
| RENDER-02 | Phase 2 | Pending |
| LAUNCH-01 | Phase 1 | Complete |
| LAUNCH-02 | Phase 3 | Pending |
| LAUNCH-03 | Phase 3 | Pending |
| WIN-01 | Phase 5 | Pending |
| WIN-02 | Phase 5 | Pending |
