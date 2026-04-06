# Phase 3: Launch Speed - Context

**Gathered:** 2026-04-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Optimize warm launch to first visible content under 100ms on Apple Silicon. This phase is profiling-driven: measure first, optimize only what the data shows is slow. The WKWebView pre-warm decision must be resolved with profiling data (implemented if beneficial, documented with evidence if rejected). Cold vs warm launch times must be separately measured and recorded.

</domain>

<decisions>
## Implementation Decisions

### WKWebView Pre-Warming
- **D-01:** Profile the current launch path first. Only implement WKWebView pre-warming if signpost data shows WKWebView creation is a significant bottleneck (>20ms of the launch path). If not a bottleneck, document the profiling evidence and skip.
- **D-02:** If pre-warming is implemented: create a hidden WKWebView during `applicationDidFinishLaunching`, pre-load the template HTML, and reuse it for the first file open. Subsequent windows create their own WKWebView as they do today.
- **D-03:** The pre-warm decision must be documented either way — success criteria #2 requires this resolution.

### Launch Profiling & Measurement
- **D-04:** Add a new signpost interval from `main()` (or earliest possible point) to first paint callback, measuring the full app-launch-to-content pipeline. This supplements the existing `open-to-paint` interval which only measures from `openFile` to first paint.
- **D-05:** Measure cold launch (first launch since boot) and warm launch (subsequent launch) separately. Record both in a profiling results document or code comment.
- **D-06:** The 100ms target applies to warm launch only (per success criteria #1).

### Optimization Strategy
- **D-07:** Profile-then-optimize approach. Use the existing OSSignposter intervals (file-read, parse, chunk-split, chunk-inject, open-to-paint) to identify the actual bottlenecks before making any changes.
- **D-08:** Only optimize stages that consume >10% of the launch path. Do not speculatively optimize things that profiling shows are fast.

### Claude's Discretion
- Whether template loading needs optimization (profile first — currently synchronous file read)
- Whether `cmark_gfm_core_extensions_ensure_registered()` should be moved earlier in the launch path
- The specific threshold for deciding WKWebView pre-warm is "worth it" (recommendation: 20ms, but adjust based on profiling data)
- Whether to add a launch-time signpost at the `main()` level or at `applicationDidFinishLaunching`

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — LAUNCH-02, LAUNCH-03 definitions and acceptance criteria

### Architecture & Prior Work
- `.planning/codebase/ARCHITECTURE.md` — Full launch flow from main.swift to first paint
- `.planning/phases/01-correctness-measurement-baseline/01-01-SUMMARY.md` — OSSignposter instrumentation details (file-read, parse, chunk-split, chunk-inject, open-to-paint intervals)
- `.planning/phases/01-correctness-measurement-baseline/01-RESEARCH.md` — WKWebView patterns and OSSignposter API usage

### Source Files (primary investigation/modification targets)
- `MDViewer/main.swift` — App entry point, earliest possible signpost insertion point
- `MDViewer/AppDelegate.swift` — applicationDidFinishLaunching, openFile dispatch, displayResult flow
- `MDViewer/WebContentView.swift` — WKWebView creation in init(frame:), potential pre-warm target
- `MDViewer/MarkdownRenderer.swift` — cmark initialization, rendering signposts

### Known Concerns
- `.planning/STATE.md` — Blocker: "WKWebView pre-warm decision requires profiled data before implementation (FEATURES.md and PITFALLS.md conflict)"

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `OSSignposter` with subsystem "com.mdviewer.app" / category "RenderingPipeline" — already instruments the full pipeline
- `appSignposter` in AppDelegate.swift — tracks open-to-paint intervals per window via ObjectIdentifier dictionary
- `renderingSignposter` in MarkdownRenderer.swift — tracks file-read, parse, chunk-split intervals
- `SplitTemplate` — loaded once at launch, reused across all file opens

### Established Patterns
- Background rendering on `DispatchQueue.global(qos: .userInitiated)`, all UI on main thread
- `loadTemplate()` called in `applicationDidFinishLaunching` and lazily via `ensureTemplateLoaded()`
- `MarkdownRenderer()` created eagerly as AppDelegate property (cmark init happens here)
- WKWebView created per-window in `WebContentView.init(frame:)` — no pooling

### Integration Points
- `main.swift` — earliest possible signpost insertion point for launch measurement
- `applicationDidFinishLaunching` — where pre-warm would be initiated
- `WebContentView.init(frame:)` — where WKWebView is currently created fresh each time
- `openFile(_:)` — the pipeline entry point, currently starts `open-to-paint` signpost
- `webContentViewDidFinishFirstPaint(_:)` — where launch measurement would end

</code_context>

<specifics>
## Specific Ideas

The STATE.md blocker notes a conflict between features (WKWebView pre-warm could help) and pitfalls (pre-warm may waste memory if user doesn't open a file immediately, or may conflict with WKWebView configuration). This phase must resolve this empirically with profiling data, not speculation.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 03-launch-speed*
*Context gathered: 2026-04-06*
