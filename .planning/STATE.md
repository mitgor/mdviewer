---
gsd_state_version: 1.0
milestone: v2.1
milestone_name: Deep Optimization
status: defining-requirements
stopped_at: null
last_updated: "2026-04-16"
last_activity: 2026-04-16
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-16)

**Core value:** Open a markdown file and see beautifully rendered content instantly
**Current focus:** Defining requirements for v2.1

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-04-16 — Milestone v2.1 started

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

### Pending Todos

None yet.

### Blockers/Concerns

- Current warm launch: 184.50ms on M4 Max (target: sub-100ms)
- Vendoring swift-cmark requires forking and maintaining a C library
- Native NSTextView path means two rendering backends to maintain
