# MDViewer

## What This Is

A fast, native macOS markdown viewer with LaTeX-inspired typography and Mermaid diagram support. Designed as a Finder-native quick preview tool — double-click a `.md` file, read it, close it. Built with AppKit + WKWebView + cmark-gfm.

## Core Value

Open a markdown file and see beautifully rendered content instantly — sub-200ms to first visible content.

## Requirements

### Validated

- ✓ Parse GFM markdown (tables, strikethrough, autolinks, task lists) — v1
- ✓ LaTeX-style typography with Latin Modern Roman fonts — v1
- ✓ Mermaid diagram rendering (async, lazy-loaded) — v1
- ✓ Progressive rendering pipeline (first screen → diagrams → remaining content) — v1
- ✓ Monospace toggle (Cmd+M) — v1
- ✓ Finder-native file association (.md, .markdown) — v1
- ✓ Multiple windows (one per file) — v1
- ✓ CLI argument file opening — v1
- ✓ Cmd+O file picker — v1
- ✓ PDF export with pagination and headers/footers (Cmd+E) — v1
- ✓ Print via PDF + Preview workaround for macOS 26 (Cmd+P) — v1
- ✓ Always-light theme (no dark mode) — v1
- ✓ Background thread markdown parsing — v1
- ✓ Cached regex patterns and single-pass entity encoding — v1
- ✓ Batched JS chunk injection — v1

### Active

- [ ] Sub-100ms launch to first visible content
- [ ] Stream large files (10MB+) without loading entire file into memory
- [ ] N-chunk progressive rendering (currently limited to 2 chunks)
- [ ] Reduce per-window memory footprint
- [ ] Fix window position persistence (currently resets every launch)
- [ ] Proper window cascading for multiple files

### Out of Scope

- Dark mode — conflicts with LaTeX aesthetic
- File editing — this is a viewer, not an editor
- File watching / live reload — quick preview tool, not a working reference
- Tabs / multi-document interface — one window per file is simpler
- Preferences window — no settings to persist

## Context

- macOS 26 (Tahoe) has a bug: WKWebView.printOperation produces blank pages. Workaround: createPDF + CGPDFDocument slicing + PDFPrintView.
- Fonts are loaded from app bundle via relative URLs in loadHTMLString baseURL.
- application(_:openFile:) fires before applicationDidFinishLaunching in AppKit — template must be loaded eagerly via ensureTemplateLoaded().
- WKProcessPool is deprecated on macOS 12+ (auto-shared).

## Constraints

- **Platform**: macOS 13+ (uses cmark-gfm SPM, WKWebView features)
- **No network**: All resources bundled (fonts, mermaid.min.js)
- **Read-only**: No file modification, no state persistence
- **Speed**: First content visible in <200ms

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| AppKit + WKWebView over SwiftUI | Fastest launch, full control over window chrome | ✓ Good |
| cmark-gfm over regex parsing | C library, <10ms parse for large files | ✓ Good |
| Mermaid via evaluateJavaScript | Lazy-loaded only when needed, no script tag in template | ✓ Good |
| createPDF over printOperation | printOperation broken on macOS 26 | ✓ Good (workaround) |
| main.swift over @main | @main didn't call applicationDidFinishLaunching | ✓ Good |
| loadHTMLString over loadFileURL | Simpler, works when template loaded before delegate fires | ✓ Good |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-06 after milestone v2.0 — speed & memory optimizations*
