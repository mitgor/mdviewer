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
- ✓ Stream large files (10MB+) via memory-mapped read — v2.0
- ✓ N-chunk progressive rendering (≤64KB block boundaries) — v2.0
- ✓ Reduced per-window memory (Mermaid script-src, WKWebView retain fix) — v2.0
- ✓ Per-file window position persistence — v2.0
- ✓ Window cascading for multiple files — v2.0
- ✓ Vendored cmark-gfm with chunked HTML callback API — v2.1 Phase 6
- ✓ WKWebView warm pool (capacity 2, async replenishment, crash recovery) — v2.1 Phase 7
- ✓ Streaming parse-to-render pipeline with buffer-reuse first-page assembly — v2.1 Phase 8
- ✓ Native NSTextView backend (AST → NSAttributedString) for mermaid/table-free files — v2.1 Phase 9
- ✓ Signed Developer ID + notarized DMG release pipeline — v2.1 release

### Active

_None. v2.1 shipped 2026-04-18; no milestone currently active._

### Out of Scope

- Dark mode — conflicts with LaTeX aesthetic
- File editing — this is a viewer, not an editor
- File watching / live reload — quick preview tool, not a working reference
- Tabs / multi-document interface — one window per file is simpler
- Preferences window — no settings to persist
- Zero-copy C-to-JS string bridge — Phase 8 research showed <0.1ms cost; IPC boundary is the real bottleneck
- Incremental cmark parsing — `cmark_parser_finish()` required before AST access; streaming must be post-parse

## Current State

**Shipped:** v2.1 Deep Optimization (2026-04-18) — [Release](https://github.com/mitgor/mdviewer/releases/tag/v2.1).

v2.1 archives: [`milestones/v2.1-ROADMAP.md`](milestones/v2.1-ROADMAP.md) · [`milestones/v2.1-REQUIREMENTS.md`](milestones/v2.1-REQUIREMENTS.md).

### Open Concerns (candidates for next milestone)

- **Sub-100ms warm launch** — target from v2.1 is instrumented but not yet measured on the shipped build. Last recorded measurement was 184.50ms on M4 Max pre-v2.1. The path is `OSSignposter(open-to-paint)`; run under Instruments.
- **Deferred human verification** — 2 UAT scenarios (phase 7, 8) and 4 VERIFICATION sign-offs (phases 6–9) acknowledged at close; see [`STATE.md`](STATE.md) Deferred Items.
- **No release automation** — the archive/sign/notarize/DMG/publish flow runs manually on the developer Mac. A GitHub Actions workflow would make releases one-click.
- **v2.0 phase docs cleanup** — phases 01–05 directories were partially deleted from the working tree during v2.1 but never formally archived to `milestones/v2.0-ROADMAP.md`.

## Current Milestone

_None active. Run `/gsd-new-milestone` to scope v2.2._

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
| WeakScriptMessageProxy over direct self | Breaks WKUserContentController retain cycle | ✓ Good |
| OSSignposter over os_signpost() | Modern Swift API, type-safe interval tracking | ✓ Good |
| mappedIfSafe over String(contentsOf:) | Avoids full-file heap allocation for 10MB+ files | ✓ Good |
| callAsyncJavaScript over evaluateJavaScript | Typed arguments eliminate injection risk from string interpolation | ✓ Good |
| Byte-size chunking over block-count chunking | ≤64KB chunks at block boundaries for true N-chunk rendering | ✓ Good |
| Vendored cmark over SPM dependency | Project-owned C library enables custom chunked API and mermaid detection | ✓ Good |
| Unified modulemap for cmark | Xcode 26 explicit modules required merging cmark_gfm + extensions | ✓ Good |
| WebViewPool over single preWarmedContentView | Generalizes pre-warm to pool of 2 with auto-replenishment and crash recovery | ✓ Good |
| pendingFileOpens guard | NSOpenPanel close triggers applicationShouldTerminateAfterLastWindowClosed before async render completes | ✓ Good |

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
*Last updated: 2026-04-18 after v2.1 milestone close (phases 06–09 shipped as [v2.1 release](https://github.com/mitgor/mdviewer/releases/tag/v2.1)).*
