---
status: partial
phase: 08-streaming-pipeline
source: [08-VERIFICATION.md, docs/perf/v2.1-measurements.md]
started: 2026-04-16T12:00:00Z
updated: 2026-04-19T14:30:00Z
---

## Current Test

[STRM-02 deferred — re-capture filed as PERF-11]

## Tests

### 1. STRM-02: Buffer reuse effectiveness
expected: Instruments Allocations trace shows assemblyBuffer retains heap block across renders (no new allocations per call)
result: DEFERRED — captured trace used wrong instrument (Logging) and wrong file routing (native path, which doesn't use assemblyBuffer). Allocations template + forced-WKWebView file required. Filed as PERF-11 in .planning/REQUIREMENTS.md for re-capture. Code path verified manually present (`removeAll(keepingCapacity: true)` in MarkdownRenderer.assembleFirstPage).

### 2. PERF-01: Sub-150ms warm launch
expected: open-to-paint signpost interval under 150ms for 2nd+ file open
result: PASS — 115.68 ms measured on M4 Max / macOS 26.4 (commit a2d609b). Trace: ~/Desktop/perf-04-wkwebview-warm.trace, Run 3, first open-to-paint interval (t=0.73s, warm process state). 34 ms below the 150 ms target. See docs/perf/v2.1-measurements.md entry #1 (PERF-04 covers PERF-01 in v2.2 numbering).

## Summary

total: 2
passed: 1
issues: 0
pending: 0
deferred: 1
skipped: 0
blocked: 0

## Gaps

- STRM-02 instrumentation re-capture pending (PERF-11) — does not block phase 08 since the code-path verification stands and the streaming pipeline functionally works.
