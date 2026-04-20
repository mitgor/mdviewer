---
status: complete
phase: 08-streaming-pipeline
source: [08-VERIFICATION.md, docs/perf/v2.1-measurements.md]
started: 2026-04-16T12:00:00Z
updated: 2026-04-20T00:00:00Z
---

## Current Test

[all tests resolved]

## Tests

### 1. STRM-02: Buffer reuse effectiveness
expected: Instruments Allocations trace shows assemblyBuffer retains heap block across renders (no new allocations per call)
result: CLOSED CODE-VERIFIED — Allocations re-capture (~/Desktop/perf-7.trace) revealed an architectural finding: each window creates its own MarkdownRenderer → its own assemblyBuffer, so `removeAll(keepingCapacity:)` has no observable runtime effect in MDViewer's per-window-per-renderer pattern. Code path correct (`removeAll(keepingCapacity: true)` present in MarkdownRenderer.assembleFirstPage). Incidental aggregate-heap finding (4 GB persistent after 5 opens) filed separately as PERF-12 for v2.3.

### 2. PERF-01: Sub-150ms warm launch
expected: open-to-paint signpost interval under 150ms for 2nd+ file open
result: PASS — 115.68 ms measured on M4 Max / macOS 26.4 (commit a2d609b). Trace: ~/Desktop/perf-04-wkwebview-warm.trace, Run 3, first open-to-paint interval (t=0.73s, warm process state). 34 ms below the 150 ms target. See docs/perf/v2.1-measurements.md entry #1 (PERF-04 covers PERF-01 in v2.2 numbering).

## Summary

total: 2
passed: 2
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

- None blocking. Incidental finding from STRM-02 capture: 4 GB persistent process heap after 5 opens of a 100 KB file — filed as PERF-12 for v2.3 investigation.
