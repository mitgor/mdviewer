# Roadmap: MDViewer

## Milestones

- ~~**v2.0 Speed & Memory**~~ - Phases 1-5 (completed 2026-04-16)
- **v2.1 Deep Optimization** - Phases 6-9 (in progress)

## Phases

<details>
<summary>v2.0 Speed & Memory (Phases 1-5) - COMPLETED 2026-04-16</summary>

- [x] **Phase 1: Correctness & Measurement Baseline** - Fix WKWebView retain cycle and add os_signpost instrumentation so all subsequent measurements are valid
- [x] **Phase 2: Large File Memory & Progressive Rendering** - Memory-mapped file reads and true N-chunk progressive rendering for 10MB+ files
- [x] **Phase 3: Launch Speed** - WKWebView pre-warm (if profiling confirms benefit) and sub-100ms warm launch
- [x] **Phase 4: Mermaid Script Loading** - Replace 3MB evaluateJavaScript bridge call with script-src loading
- [x] **Phase 5: Window Management** - Persistent window positions and proper multi-window cascading

### Phase 1: Correctness & Measurement Baseline
**Goal**: Every window close releases all WKWebView memory, and pipeline instrumentation produces valid profiling data
**Depends on**: Nothing (first phase)
**Requirements**: MEM-01, LAUNCH-01
**Success Criteria** (what must be TRUE):
  1. Closing a markdown window deallocates its WKWebView (verified via deinit logging or Instruments)
  2. Opening and closing 10 windows in sequence does not grow sustained RSS
  3. os_signpost intervals appear in Instruments for file-read, parse, chunk-split, and chunk-inject phases
  4. Baseline measurements (cold launch, warm launch, peak RSS for 10MB file) are recorded
**Plans**: 1 plan
Plans:
- [x] 01-01-PLAN.md -- Fix WKWebView retain cycle and add OSSignposter pipeline instrumentation

### Phase 2: Large File Memory & Progressive Rendering
**Goal**: Users can open 10MB+ markdown files without memory spikes, and content appears progressively in multiple chunks
**Depends on**: Phase 1
**Requirements**: MEM-02, RENDER-01, RENDER-02
**Success Criteria** (what must be TRUE):
  1. Opening a 10MB markdown file does not spike heap beyond 2x file size
  2. A large document renders progressively in multiple visible stages
  3. Chunk injection uses typed arguments (no string-interpolated JavaScript)
  4. First screen of content appears before remaining chunks finish loading
**Plans**: 2 plans
Plans:
- [x] 02-01-PLAN.md -- Memory-mapped file read and byte-size N-chunk splitting
- [x] 02-02-PLAN.md -- Replace evaluateJavaScript with callAsyncJavaScript for typed chunk injection

### Phase 3: Launch Speed
**Goal**: Measure and optimize launch-to-paint pipeline; WKWebView pre-warm implemented and profiled
**Depends on**: Phase 2
**Requirements**: LAUNCH-02
**Success Criteria** (what must be TRUE):
  1. WKWebView pre-warm decision is resolved with profiling data
  2. Cold vs warm launch times are separately measured and recorded
  3. Warm launch-to-paint is profiled with actual Instruments data
**Plans**: 3 plans
Plans:
- [x] 03-01-PLAN.md -- Add launch-to-paint signpost for end-to-end launch measurement
- [x] 03-02-PLAN.md -- Profile launch path, resolve WKWebView pre-warm decision, record timing data
- [x] 03-03-PLAN.md -- Gap closure: Run Instruments profiling and record actual measured timing data

### Phase 4: Mermaid Script Loading
**Goal**: Mermaid diagrams render without a 3MB IPC bridge call per window
**Depends on**: Phase 1
**Requirements**: MEM-03
**Success Criteria** (what must be TRUE):
  1. A markdown file with Mermaid diagrams renders correctly with diagrams visible
  2. Instruments shows no multi-megabyte evaluateJavaScript IPC call during Mermaid initialization
  3. Windows without Mermaid content do not load mermaid.min.js at all
**Plans**: 1 plan
Plans:
- [x] 04-01-PLAN.md -- Replace evaluateJavaScript Mermaid loading with script-src injection

### Phase 5: Window Management
**Goal**: Windows remember their position across launches and multiple windows cascade properly
**Depends on**: Phase 1
**Requirements**: WIN-01, WIN-02
**Success Criteria** (what must be TRUE):
  1. User moves a window, quits, relaunches with the same file -- window appears at the saved position
  2. Opening three files simultaneously produces three visible, cascaded windows
  3. Window position persistence does not conflict across different files
**Plans**: 1 plan
Plans:
- [x] 05-01-PLAN.md -- Per-file window position persistence and multi-window cascading

</details>

### v2.1 Deep Optimization (In Progress)

**Milestone Goal:** Dramatically reduce launch-to-paint time through architectural optimizations -- vendored cmark with direct-to-chunk output, WKWebView pooling, streaming pipeline, and native NSTextView rendering for simple files.

- [ ] **Phase 6: Vendored cmark** - Vendor swift-cmark into the Xcode project with a chunked HTML callback API that eliminates regex-based post-processing
- [ ] **Phase 7: WKWebView Pool** - Pre-warmed pool of WKWebView instances for instant 2nd+ file opens
- [ ] **Phase 8: Streaming Pipeline** - First chunk delivered to WKWebView while remaining chunks are still being rendered from the AST
- [ ] **Phase 9: Native Text Rendering** - NSTextView backend for mermaid-free files, bypassing WKWebView entirely

## Phase Details

### Phase 6: Vendored cmark
**Goal**: Markdown parsing uses a project-owned cmark with a chunked callback API, eliminating all regex-based HTML post-processing
**Depends on**: Phase 5 (v2.0 complete)
**Requirements**: CMARK-01, CMARK-02, CMARK-03, CMARK-04, CMARK-05, CMARK-06
**Success Criteria** (what must be TRUE):
  1. App builds and runs with vendored cmark sources compiled directly in the Xcode project (no SPM swift-cmark dependency)
  2. MarkdownRenderer receives HTML in chunks via callback (no regex splitting of a monolithic HTML string)
  3. Mermaid code blocks produce placeholder divs directly from the C renderer (no regex scan of rendered HTML)
  4. Opening any previously-working markdown file produces identical rendered output to the current pipeline
  5. Rendering a file twice reuses the cached extension list (no per-render cmark_find_syntax_extension calls)
**Plans**: 3 plans
Plans:
- [x] 06-01-PLAN.md -- Vendor cmark-gfm sources and configure static library build targets
- [x] 06-02-PLAN.md -- Add chunked HTML callback API and mermaid detection to vendored html.c
- [x] 06-03-PLAN.md -- Rewrite MarkdownRenderer to use chunked C API with cached extensions

### Phase 7: WKWebView Pool
**Goal**: Opening a second (or subsequent) file delivers content to a pre-warmed WKWebView with zero initialization delay
**Depends on**: Phase 6
**Requirements**: POOL-01, POOL-02, POOL-03, PERF-03
**Success Criteria** (what must be TRUE):
  1. After the first file is open, opening a second file shows content in under 100ms (measured via OSSignposter)
  2. Pool replenishes automatically after a view is acquired (pool never stays empty)
  3. If a WebContent process crashes, the pool discards the dead view and creates a replacement
**Plans**: 2 plans
Plans:
- [x] 07-01-PLAN.md -- Create WebViewPool class and add pool support methods to WebContentView
- [x] 07-02-PLAN.md -- Integrate pool into AppDelegate and add unit tests

### Phase 8: Streaming Pipeline
**Goal**: First visible content appears while the parser is still producing remaining chunks, closing the gap to sub-150ms warm launch
**Depends on**: Phase 6
**Requirements**: STRM-01, STRM-02, PERF-01
**Success Criteria** (what must be TRUE):
  1. For a large file, the first HTML chunk is delivered to WKWebView before all chunks have been produced
  2. Template concatenation does not create new String allocations per render (buffer reuse verified via Instruments allocations trace)
  3. Warm launch to first visible content is under 150ms for the WKWebView path (measured via OSSignposter)
**Plans**: 2 plans
Plans:
- [x] 08-01-PLAN.md -- Streaming render API with buffer-reuse template assembly
- [ ] 08-02-PLAN.md -- Wire streaming pipeline into AppDelegate and WebContentView

### Phase 9: Native Text Rendering
**Goal**: Simple markdown files (no mermaid, no GFM tables) render via NSTextView, bypassing WKWebView for dramatically faster display
**Depends on**: Phase 6
**Requirements**: NATV-01, NATV-02, NATV-03, NATV-04, PERF-02
**Success Criteria** (what must be TRUE):
  1. A markdown file without mermaid or GFM tables renders in an NSTextView window (no WKWebView created)
  2. Native rendering walks the cmark AST directly to build NSAttributedString (no HTML intermediate step)
  3. Native-rendered text uses Latin Modern Roman typography matching the WKWebView path visually
  4. User can toggle between native and web rendering via menu item if visual differences arise
  5. Warm launch to first visible content is under 100ms for the NSTextView path (measured via OSSignposter)
**Plans**: 2 plans
Plans:
- [ ] 08-01-PLAN.md -- Streaming render API with buffer-reuse template assembly
- [ ] 08-02-PLAN.md -- Wire streaming pipeline into AppDelegate and WebContentView
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 6 -> 7 -> 8 -> 9
(Phases 7, 8, 9 all depend on Phase 6; sequenced 7 -> 8 -> 9 for incremental validation)

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Correctness & Measurement Baseline | v2.0 | 1/1 | Complete | 2026-04-06 |
| 2. Large File Memory & Progressive Rendering | v2.0 | 2/2 | Complete | 2026-04-16 |
| 3. Launch Speed | v2.0 | 3/3 | Complete | 2026-04-16 |
| 4. Mermaid Script Loading | v2.0 | 1/1 | Complete | 2026-04-16 |
| 5. Window Management | v2.0 | 1/1 | Complete | 2026-04-16 |
| 6. Vendored cmark | v2.1 | 0/3 | Not started | - |
| 7. WKWebView Pool | v2.1 | 0/2 | Not started | - |
| 8. Streaming Pipeline | v2.1 | 0/? | Not started | - |
| 9. Native Text Rendering | v2.1 | 0/? | Not started | - |
