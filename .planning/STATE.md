---
gsd_state_version: 1.0
milestone: v2.1
milestone_name: Deep Optimization
status: ready-to-plan
stopped_at: null
last_updated: "2026-04-16"
last_activity: 2026-04-16
progress:
  total_phases: 4
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-16)

**Core value:** Open a markdown file and see beautifully rendered content instantly
**Current focus:** Phase 6 - Vendored cmark

## Current Position

Phase: 6 of 9 (Vendored cmark) -- first phase of v2.1
Plan: 0 of ? in current phase
Status: Ready to plan
Last activity: 2026-04-16 -- Roadmap created for v2.1 Deep Optimization

Progress: [..........] 0% (v2.1 phases)

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [v2.0] Module-level renderingSignposter constant (MarkdownRenderer is stateless)
- [v2.0] mappedIfSafe over alwaysMapped for graceful fallback on unsafe volumes
- [v2.0] callAsyncJavaScript with typed arguments for chunk injection
- [v2.0] WKWebView pre-warm implemented (~40ms savings)
- [v2.0] Script-src injection for mermaid.min.js (eliminates 3MB IPC)
- [v2.0] Per-file autosave name format MDViewer:{absolutePath}
- [v2.1] Zero-copy C-to-JS bridge deferred (research: <0.1ms cost)
- [v2.1] Incremental cmark parsing not viable (cmark_parser_finish required before AST)

### Pending Todos

None yet.

### Blockers/Concerns

- Current warm launch: 184.50ms on M4 Max (target: sub-100ms)
- Vendoring swift-cmark requires forking and maintaining a C library
- Native NSTextView path means two rendering backends to maintain
- Phase 6 (vendored cmark) is critical foundation -- Phases 7-9 all depend on it

## Session Continuity

Last session: 2026-04-16
Stopped at: Roadmap created for v2.1 milestone
Resume file: None
