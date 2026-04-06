---
phase: 04-mermaid-script-loading
plan: 01
subsystem: rendering
tags: [wkwebview, mermaid, ipc, script-injection, memory]

# Dependency graph
requires:
  - phase: none
    provides: existing mermaid loading via evaluateJavaScript
provides:
  - "Script-src Mermaid loading eliminating 3MB IPC per Mermaid window"
  - "Graceful onerror fallback showing raw mermaid source on load failure"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: ["DOM script-src injection for large JS bundle loading in WKWebView"]

key-files:
  created: []
  modified:
    - MDViewer/WebContentView.swift
    - MDViewer/Resources/template.html

key-decisions:
  - "Fire-and-forget evaluateJavaScript for DOM injection snippet (no callAsyncJavaScript needed for ~350 byte payload with no user data)"
  - "No static mermaidJS cache needed -- WebKit handles process-level disk caching for script-src loads"

patterns-established:
  - "Script-src injection: use DOM createElement('script') + src attribute for large JS bundles instead of evaluateJavaScript with full source"

requirements-completed: [MEM-03]

# Metrics
duration: 1min
completed: 2026-04-06
---

# Phase 04 Plan 01: Mermaid Script-Src Injection Summary

**Replaced 3MB evaluateJavaScript IPC bridge call with ~350 byte DOM script-src injection for Mermaid loading**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-06T21:54:52Z
- **Completed:** 2026-04-06T21:55:44Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Eliminated ~3MB IPC serialization per Mermaid-containing window by switching to script-src injection
- Removed static mermaidJS/mermaidJSLoaded class properties (WebKit handles caching)
- Added onerror fallback that replaces mermaid placeholders with raw source code on load failure
- Updated template.html comment to reflect new loading mechanism

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace evaluateJavaScript Mermaid loading with script-src injection** - `629ff3b` (feat)
2. **Task 2: Update template.html comment to reflect script-src loading** - `dd033bb` (chore)

## Files Created/Modified
- `MDViewer/WebContentView.swift` - Replaced loadAndInitMermaid() with script-src injection, removed static cache
- `MDViewer/Resources/template.html` - Updated comment from evaluateJavaScript to script-src injection

## Decisions Made
- Used fire-and-forget evaluateJavaScript (not callAsyncJavaScript) for the DOM injection snippet since it carries no user data arguments
- Removed static mermaidJS cache entirely -- each WKWebView loads from disk independently and WebKit handles process-level caching

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- MEM-03 satisfied: Mermaid loading no longer sends 3MB over IPC bridge
- Conditional loading preserved (hasMermaid gate unchanged)
- Ready for any subsequent memory optimization phases

---
*Phase: 04-mermaid-script-loading*
*Completed: 2026-04-06*
