# Roadmap: MDViewer v2.0 — Speed & Memory

## Overview

This milestone hardens MDViewer's existing pipeline for correctness, memory efficiency, and launch speed. The work follows a strict dependency chain: fix memory leaks and add instrumentation first (so measurements are valid), then optimize large-file memory and chunking, then tackle launch latency, then eliminate the Mermaid IPC overhead, and finally polish window management. No new dependencies are added — every change uses existing Apple and cmark-gfm APIs.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Correctness & Measurement Baseline** - Fix WKWebView retain cycle and add os_signpost instrumentation so all subsequent measurements are valid
- [ ] **Phase 2: Large File Memory & Progressive Rendering** - Memory-mapped file reads and true N-chunk progressive rendering for 10MB+ files
- [ ] **Phase 3: Launch Speed** - WKWebView pre-warm (if profiling confirms benefit) and sub-100ms warm launch
- [ ] **Phase 4: Mermaid Script Loading** - Replace 3MB evaluateJavaScript bridge call with script-src loading
- [ ] **Phase 5: Window Management** - Persistent window positions and proper multi-window cascading

## Phase Details

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
- [x] 01-01-PLAN.md — Fix WKWebView retain cycle and add OSSignposter pipeline instrumentation

### Phase 2: Large File Memory & Progressive Rendering
**Goal**: Users can open 10MB+ markdown files without memory spikes, and content appears progressively in multiple chunks
**Depends on**: Phase 1
**Requirements**: MEM-02, RENDER-01, RENDER-02
**Success Criteria** (what must be TRUE):
  1. Opening a 10MB markdown file does not spike heap beyond 2x file size (memory-mapped read avoids full-file heap allocation)
  2. A large document renders progressively in multiple visible stages (not a single flash of content)
  3. Chunk injection uses typed arguments (no string-interpolated JavaScript with user content)
  4. First screen of content appears before remaining chunks finish loading
**Plans**: TBD

### Phase 3: Launch Speed
**Goal**: Warm launch to first visible content completes in under 100ms on Apple Silicon
**Depends on**: Phase 2
**Requirements**: LAUNCH-02, LAUNCH-03
**Success Criteria** (what must be TRUE):
  1. Warm launch (app already launched once since boot) shows first markdown content in under 100ms (measured via os_signpost)
  2. WKWebView pre-warm decision is resolved with profiling data (implemented if beneficial, documented if rejected)
  3. Cold vs warm launch times are separately measured and recorded
**Plans**: TBD

### Phase 4: Mermaid Script Loading
**Goal**: Mermaid diagrams render without a 3MB IPC bridge call per window
**Depends on**: Phase 1
**Requirements**: MEM-03
**Success Criteria** (what must be TRUE):
  1. A markdown file with Mermaid diagrams renders correctly with diagrams visible
  2. Instruments shows no multi-megabyte evaluateJavaScript IPC call during Mermaid initialization
  3. Windows without Mermaid content do not load mermaid.min.js at all
**Plans**: TBD

### Phase 5: Window Management
**Goal**: Windows remember their position across launches and multiple windows cascade properly
**Depends on**: Phase 1
**Requirements**: WIN-01, WIN-02
**Success Criteria** (what must be TRUE):
  1. User moves a window, quits, relaunches with the same file — window appears at the saved position
  2. Opening three files simultaneously produces three visible, cascaded windows (not stacked at identical coordinates)
  3. Window position persistence does not conflict across different files
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5
(Phase 4 depends only on Phase 1, but executes after Phase 3 for sequencing simplicity)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Correctness & Measurement Baseline | 1/1 | Complete | 2026-04-06 |
| 2. Large File Memory & Progressive Rendering | 0/0 | Not started | - |
| 3. Launch Speed | 0/0 | Not started | - |
| 4. Mermaid Script Loading | 0/0 | Not started | - |
| 5. Window Management | 0/0 | Not started | - |
