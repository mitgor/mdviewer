# Phase 3: Launch Speed - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-06
**Phase:** 03-launch-speed
**Areas discussed:** WKWebView pre-warming strategy, Launch profiling approach, Template loading optimization, cmark initialization timing
**Mode:** --auto (all decisions auto-selected with recommended defaults)

---

## WKWebView Pre-Warming Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Profile first, implement if data supports | Measure WKWebView creation time, pre-warm only if >20ms bottleneck | ✓ |
| Always pre-warm | Create hidden WKWebView at launch regardless of profiling data | |
| Skip pre-warming entirely | Assume WKWebView creation is fast enough | |

**User's choice:** [auto] Profile first, implement if data supports (recommended default)
**Notes:** Success criteria #2 requires the pre-warm decision to be resolved with profiling data. STATE.md flags this as a known blocker.

---

## Launch Profiling Approach

| Option | Description | Selected |
|--------|-------------|----------|
| New app-launch signpost + existing pipeline intervals | Add main()-to-first-paint interval, use existing OSSignposter intervals | ✓ |
| External profiling only (Instruments) | Rely on Instruments without code-level measurement | |
| Custom timing code | Use Date/CFAbsoluteTimeGetCurrent instead of signposts | |

**User's choice:** [auto] New app-launch signpost + existing pipeline intervals (recommended default)
**Notes:** Builds on Phase 1 instrumentation foundation. Cold vs warm must be measured separately per success criteria #3.

---

## Template Loading Optimization

| Option | Description | Selected |
|--------|-------------|----------|
| Claude's discretion (profile first) | Optimize only if signpost data shows template loading is significant | ✓ |
| Pre-compile template | Cache compiled template across launches | |
| Keep as-is | Current synchronous load is likely fast enough | |

**User's choice:** [auto] Claude's discretion (recommended default)
**Notes:** Template is a single HTML file, likely loads in <1ms. Profile before optimizing.

---

## cmark Initialization Timing

| Option | Description | Selected |
|--------|-------------|----------|
| Claude's discretion (profile first) | Move cmark init earlier only if profiling shows it's slow | ✓ |
| Move to applicationDidFinishLaunching | Initialize before any file open | |
| Keep in MarkdownRenderer.init() | Current location, initialized eagerly as property | |

**User's choice:** [auto] Claude's discretion (recommended default)
**Notes:** cmark_gfm_core_extensions_ensure_registered() is a C function call, likely very fast.

---

## Claude's Discretion

- Template loading optimization approach
- cmark initialization timing
- WKWebView pre-warm threshold (20ms recommendation)
- Launch signpost insertion point (main.swift vs applicationDidFinishLaunching)

## Deferred Ideas

None — discussion stayed within phase scope.
