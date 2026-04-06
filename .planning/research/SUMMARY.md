# Project Research Summary

**Project:** MDViewer — macOS AppKit + WKWebView Markdown Viewer
**Domain:** Native macOS document viewer performance optimization
**Researched:** 2026-04-03
**Confidence:** HIGH

## Executive Summary

MDViewer is a native macOS markdown viewer built on a correct and stable stack (AppKit + WKWebView + cmark-gfm). This milestone is not a stack replacement — it is a targeted performance and correctness hardening of the existing pipeline. The four research areas converge on the same diagnosis: multiple known bugs (a WKWebView retain cycle, broken window frame persistence, a 3 MB Mermaid JS bridge call) are actively masking performance measurements and must be fixed before any latency or memory work is meaningful. The primary launch latency bottleneck is WKWebView process initialization (80–200ms cold), not markdown parsing (which already runs under 10ms in C via cmark-gfm).

The recommended implementation order is: fix correctness blockers first (retain cycle, firstPaint double-fire guard), then address large-file memory (memory-mapped reads, N-chunk splitting), then launch latency (WKWebView pre-warm, static linking), then Mermaid loading (replace JS bridge with `<script src>`), and finally window management polish (frame persistence). This ordering is driven by a hard dependency: per-window memory measurements are invalid until the retain cycle is fixed, and large-file performance is unmeasurable until memory-mapped reading is in place. Every optimization PR must include a before/after Instruments measurement — the single biggest risk to this milestone is optimizing the wrong thing without profiling data.

The stack does not need changes. No new dependencies should be added. The entire scope is refactoring within existing APIs (Foundation, WebKit, AppKit, cmark-gfm) that are all HIGH confidence and well-documented. The primary technical uncertainty is whether WKWebView pre-warming produces meaningful savings given that MDViewer typically opens one webview per launch immediately on startup — PITFALLS.md explicitly warns this pre-warm may add RSS with no latency benefit, contradicting the FEATURES.md recommendation. This needs a profiled measurement to resolve.

---

## Key Findings

### Recommended Stack

The existing stack (AppKit + WKWebView + cmark-gfm, Swift 5.9, macOS 13+) is correct and requires no replacement. STACK.md recommends specific API upgrades within this stack: `Data(contentsOf:options:.mappedIfSafe)` for file reads, `callAsyncJavaScript` to replace `evaluateJavaScript` for chunk injection, `OSSignposter` for pipeline instrumentation, and `setFrameAutosaveName` for window position persistence. The one build-system change worth investigating is switching swift-cmark from dynamic to static linking to eliminate one dyld load phase.

**Core technologies:**
- `cmark-gfm` (C library via swift-cmark): Markdown parsing — already <10ms for large files; no replacement needed
- `WKWebView` (WebKit): HTML rendering — required for Mermaid/LaTeX; memory managed via weak-proxy and pre-warm pattern
- `Data(contentsOf:options:.mappedIfSafe)` (Foundation): File I/O — demand-paged mmap eliminates heap spike for large files
- `callAsyncJavaScript` (WebKit macOS 11+): JS chunk injection — replaces unsafe manual string escaping with typed serialization
- `OSSignposter` (os framework): Pipeline instrumentation — zero-overhead when disabled; required for credible measurement
- `setFrameAutosaveName` (AppKit): Window persistence — zero custom code; AppKit handles multi-screen and Spaces automatically

**Critical version note:** `callAsyncJavaScript` requires macOS 11+. The project targets macOS 13+, so no availability guard is needed. Do not migrate the rendering pipeline to Swift async/await in this milestone — WKWebView's main-actor constraints make that a separate scope.

### Expected Features

See `.planning/research/FEATURES.md` for the full feature table.

**Must have (table stakes — currently broken or absent):**
- Sub-100ms first visible content — currently ~150–200ms; WKWebView cold init is the bottleneck
- Memory release on window close — broken; retain cycle in `WKUserContentController` prevents deallocation
- Correct window position restore — broken; `loadSavedFrame` always returns nil
- 10 MB+ file support without OOM — not implemented; `String(contentsOf:)` loads entire file into heap

**Should have (differentiators — currently limited):**
- True N-chunk progressive rendering — currently only 2 chunks; second chunk can be multi-megabyte
- Memory-mapped file reading — reduces peak RSS for large files; enables true streaming path
- Mermaid via `<script src>` — eliminates 3 MB IPC bridge call per diagram window
- `callAsyncJavaScript` with typed arguments — correctness fix eliminating escaping vulnerabilities
- WKWebView pre-warm — primary lever for sub-100ms first paint (conditional on profiling result)

**Defer:**
- Dark mode support — explicitly out of scope per PROJECT.md
- File watching / live reload — explicitly out of scope per PROJECT.md
- Swift async/await full migration — separate milestone; WKWebView main-actor constraints complicate path
- DispatchIO streaming for files under 50 MB — memory mapping handles the common case

### Architecture Approach

The optimized architecture is a producer-consumer pipeline where file I/O, parsing, HTML chunking, and injection are all separately staged. ARCHITECTURE.md documents the full before/after data flow. The key structural change is that `MarkdownRenderer.chunkHTML` produces N chunks (64 KB target per chunk) rather than the current 2-chunk fixed split, and `WebContentView.injectRemainingChunks` delivers those chunks via `callAsyncJavaScript` with typed arguments rather than manual JS string construction. The JS-side 16ms stagger infrastructure already exists and requires no changes.

**Major components:**
1. `MarkdownRenderer` — file read + cmark parse + N-chunk HTML split; stays on background queue
2. `WebContentView` — WKWebView host + chunk injection + firstPaint signal handler; must be `@MainActor`
3. `AppDelegate` — launch orchestration + pre-warm pool (if warranted by measurement); template loading
4. `MarkdownWindow` — window lifecycle, frame persistence via `setFrameAutosaveName`
5. `template.html` — receives `<script src="mermaid.min.js">` tag (Option B: conditional via WKUserScript)

**What does not change:**
- cmark C API call sequence (`cmark_parser_feed` / `cmark_render_html`) — already optimal
- `SplitTemplate` pre-split at launch — O(1) concatenation, already optimal
- Background thread dispatch for parsing — already correct
- `loadHTMLString` with `baseURL: Bundle.main.resourceURL` — do not switch to `loadFileURL`

### Critical Pitfalls

See `.planning/research/PITFALLS.md` for all 13 pitfalls with full detail.

1. **Optimizing without measuring first** — Establish Instruments baselines (cold launch, warm launch, peak RSS, sustained RSS) before writing any optimization code. Every "performance" PR requires a before/after measurement. cmark is already fast; the bottleneck is WKWebView process spawn.

2. **WKWebView retain cycle via script message handler** — `contentController.add(self, name: "firstPaint")` creates a strong reference cycle that prevents `WebContentView` from ever deallocating. Fix with a `WeakScriptMessageProxy` wrapper as the very first code change. Without this fix, all RSS measurements are invalid.

3. **`evaluateJavaScript` with large payloads** — Passing a multi-MB second chunk through `evaluateJavaScript` crosses the IPC boundary synchronously and blocks the main thread for hundreds of milliseconds. Switch to `callAsyncJavaScript` with typed arguments and implement true N-chunk splitting (≤64 KB per chunk).

4. **`String(contentsOf:)` for large files** — Allocates the full file in heap plus conversion overhead (up to 3x file size peak). Replace with `Data(contentsOf:options:.mappedIfSafe)` and pass the `Data` buffer directly to the cmark C API.

5. **Conflating warm and cold launch measurements** — Always report both. Cold launch on macOS 13+ with WKWebView is typically 150–300ms and mostly outside the app's control. The sub-100ms target should be defined as warm launch. Use `purge` or the App Launch Instruments template for cold measurements.

6. **Pre-warming WKWebView may be counterproductive** — PITFALLS.md specifically warns that MDViewer always needs a webview immediately on launch, so pre-allocation adds RSS without reducing latency. FEATURES.md recommends pre-warming. This conflict must be resolved by profiling before committing to the pre-warm pattern.

---

## Implications for Roadmap

Based on research, the dependency graph drives a clear 5-phase structure. Correctness must precede measurement; measurement must precede optimization.

### Phase 1: Correctness Blockers and Measurement Baseline

**Rationale:** The retain cycle makes all memory measurements invalid. The `developerExtrasEnabled` and `CMARK_OPT_UNSAFE` issues are one-line fixes. Establish Instruments baselines before any optimization work begins. This phase costs the least and unlocks everything else.

**Delivers:** Valid memory measurements, no WKWebView leaks on window close, profiling infrastructure in place

**Addresses:**
- Fix `WKUserContentController` retain cycle (WeakScriptMessageProxy pattern)
- Add `deinit` assertions to `WebContentView` and `MarkdownWindow`
- Add `hasProcessedFirstPaint` guard against double-injection
- Gate `developerExtrasEnabled` behind `#if DEBUG`
- Add `// intentional` comment on `CMARK_OPT_UNSAFE`
- Pin `swift-cmark` to a revision instead of branch
- Instrument pipeline with `OSSignposter` markers (file read, parse, chunk, inject)
- Record baseline measurements: cold launch, warm launch, peak RSS (10 MB file), sustained RSS

**Avoids:** Pitfall 1 (optimizing without measuring), Pitfall 2 (retain cycle invalidating measurements), Pitfall 11 (developerExtrasEnabled in production)

---

### Phase 2: Large File Memory and Chunking

**Rationale:** `String(contentsOf:)` is the most concrete, highest-confidence fix in the codebase. It is also a prerequisite for any credible "10 MB+ support" claim. N-chunk splitting is a pure Swift-side change that the existing JS infrastructure already supports.

**Delivers:** 10 MB+ files open without OOM; per-window RSS is sub-linear in file size; progressive rendering works for large documents

**Addresses:**
- Replace `String(contentsOf:)` with `Data(contentsOf:options:.mappedIfSafe)`
- Pass `Data` buffer directly to cmark C API (no full-file Swift String)
- Replace 2-chunk fixed split with byte-budget N-chunk splitting (64 KB target)
- Replace `injectRemainingChunks` string construction with `callAsyncJavaScript` + typed args
- Fix `encodeHTMLEntities` to use `replacingOccurrences` instead of character loop
- Add explicit `config.suppressesIncrementalRendering = false`

**Uses:** `Data(contentsOf:options:.mappedIfSafe)`, `cmark_parser_feed`/`cmark_parser_finish`, `callAsyncJavaScript`

**Avoids:** Pitfall 3 (large `evaluateJavaScript` payloads), Pitfall 5 (`String(contentsOf:)` memory spike)

---

### Phase 3: Launch Latency

**Rationale:** Latency work should come after memory/correctness, so baselines from Phase 1 are valid and Phase 2's chunking changes are in place. This phase targets the sub-100ms warm launch goal.

**Delivers:** Sub-100ms warm first-paint; reduced pre-main dyld time (if static linking is viable)

**Addresses:**
- Profile pre-main time with App Launch Instruments template
- Investigate static linking of swift-cmark (confirm SPM support in `project.yml`)
- Profile `ensureTemplateLoaded()` — move to `DispatchQueue.global` if >5ms
- Measure WKWebView pre-warm: profile cold vs. warm launch with and without pre-allocation; only implement if measurement shows gain without RSS cost
- Add `@MainActor` annotation to `WebContentView` (prerequisite for any Swift 6 migration)

**Avoids:** Pitfall 1 (measure before implementing pre-warm), Pitfall 6 (warm vs. cold measurement confusion), Pitfall 7 (pre-warm adding RSS with no benefit), Pitfall 9 (missing @MainActor before refactor)

**Research flag:** WKWebView pre-warm decision requires profiled data. Do not commit to implementation until measurement resolves the FEATURES.md vs. PITFALLS.md conflict.

---

### Phase 4: Mermaid Loading

**Rationale:** Mermaid loading is independent of all other pipeline changes and can be done at any point, but it is cleanest after the chunk injection refactor (Phase 2) because it removes the static `mermaidJS` / `mermaidJSLoaded` vars that Phase 2 may need to reason about.

**Delivers:** 3 MB IPC bridge call eliminated per diagram window; WebKit bytecode caching across windows; main-thread disk read eliminated

**Addresses:**
- Remove `loadAndInitMermaid()`, `mermaidJS` static, `mermaidJSLoaded` static
- Add conditional `<script src="mermaid.min.js">` via `WKUserScript` at `.atDocumentEnd` when `hasMermaid == true` (Option B from ARCHITECTURE.md)
- Verify `initMermaid()` guards correctly on absence of `.mermaid-placeholder` elements

**Avoids:** Pitfall 4 (Mermaid via JS bridge on every window)

---

### Phase 5: Window Management Polish

**Rationale:** Frame persistence is a user-visible correctness fix, not a performance fix. It should come last because it is independent of all other phases, and the static `frameSaveKey` bug should be resolved before the fix is implemented (fixing persistence with the wrong key would actively create incorrect behavior).

**Delivers:** Windows restore to their last position; multi-window position does not conflict

**Addresses:**
- Fix `loadSavedFrame()` stub — rely on AppKit's automatic frame restoration via `setFrameAutosaveName`
- Use per-file or cascade-based key to avoid last-write-wins collision
- Verify `isReleasedWhenClosed` and delegate chain are fully nilled on close
- Confirm deallocation via `deinit` log on both `MarkdownWindow` and `WebContentView`

**Avoids:** Pitfall 8 (shared frame key), Pitfall 10 (isReleasedWhenClosed without fixing delegate chain)

---

### Phase Ordering Rationale

- Phase 1 must come first: without the retain cycle fix, all subsequent memory measurements are meaningless. Profiling infrastructure (`OSSignposter`) must exist before any optimization can be validated.
- Phase 2 before Phase 3: large-file memory fixes are higher confidence than launch latency fixes. The `String(contentsOf:)` replacement and N-chunking have no measurement uncertainty — the APIs are well-documented and the current code is demonstrably wrong for large files.
- Phase 3 deferred until after Phase 2: launch latency work (especially pre-warm) has a measurement-dependent decision. The conflict between FEATURES.md and PITFALLS.md on WKWebView pre-warming must be resolved empirically.
- Phase 4 is independent: Mermaid loading can be done as a standalone PR at any point after Phase 1.
- Phase 5 last: window management is polish; does not block any milestone goal.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3 (Launch Latency):** WKWebView pre-warm decision requires a profiled measurement on the actual hardware and usage pattern (single webview opened immediately on launch). The FEATURES.md and PITFALLS.md recommendations conflict and cannot be resolved without data.
- **Phase 3 (Launch Latency):** Static linking feasibility depends on the swift-cmark SPM package configuration. Needs verification against `project.yml` before committing to this approach.

Phases with standard patterns (can proceed without additional research):
- **Phase 1 (Correctness):** WeakScriptMessageProxy pattern is canonical and well-documented. OSSignposter API is stable and covered by official Apple docs.
- **Phase 2 (Large File/Chunking):** All APIs are official Apple/cmark documentation. `Data(contentsOf:options:.mappedIfSafe)` and `callAsyncJavaScript` are HIGH confidence.
- **Phase 4 (Mermaid):** `<script src>` via WKUserScript is the same mechanism already used for fonts. HIGH confidence.
- **Phase 5 (Window):** `setFrameAutosaveName` is standard AppKit. HIGH confidence.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | No replacements needed; all recommended APIs are official Apple documentation, stable since macOS 11–13 |
| Features | HIGH | Priority ranking grounded in codebase analysis (CONCERNS.md) and well-established WebKit behavior |
| Architecture | HIGH | Data flow changes are localized; existing components' responsibilities are unchanged; all new APIs verified |
| Pitfalls | HIGH | Most pitfalls are confirmed existing bugs (CONCERNS.md) or well-documented WebKit/AppKit issues with canonical fixes |

**Overall confidence:** HIGH

### Gaps to Address

- **WKWebView pre-warm ROI:** FEATURES.md recommends it; PITFALLS.md warns it may add RSS for no gain on MDViewer's single-webview-per-launch pattern. Resolve by profiling cold launch time with and without the pre-warm, measuring both latency and RSS delta. Decision must be data-driven before Phase 3 implementation begins.

- **Static linking feasibility:** STACK.md recommends switching swift-cmark to static to reduce dyld load time, but notes this depends on the SPM configuration in `project.yml`. Verify before implementing.

- **50 MB+ file support:** Memory-mapped reading and N-chunk splitting handle files up to ~50 MB well. Above that, cmark's AST heap becomes the dominant memory consumer. `DispatchIO`-based streaming with `cmark_parser_feed` is the correct next step, but it is out of scope for this milestone. Flag for a future research phase if any user reports OOM on very large files.

- **Swift 6 concurrency migration:** Adding `@MainActor` to `WebContentView` in Phase 3 is a prerequisite. Full `async/await` migration of the rendering pipeline is a separate milestone (WKWebView main-actor constraints require a dedicated audit).

---

## Sources

### Primary (HIGH confidence)

- Apple Developer Documentation: `Data(contentsOf:options:)`, `WKWebView.callAsyncJavaScript`, `WKWebViewConfiguration`, `NSWindow.setFrameAutosaveName`, `OSSignposter` — developer.apple.com
- Apple WWDC 2019: Optimizing App Launch — developer.apple.com/videos/play/wwdc2019/423
- Apple: Reducing Your App's Launch Time — developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time
- cmark-gfm header API reference (confirmed): github.com/github/cmark-gfm/blob/master/src/cmark-gfm.h
- Apple File Management Guide: Mapping Files Into Memory — developer.apple.com/library/archive

### Secondary (MEDIUM confidence)

- WKWebView memory leaks analysis — embrace.io/blog/wkwebview-memory-leaks
- WKWebView warm-up community pattern — github.com/bernikovich/WebViewWarmUper
- WKWebView evaluateJavaScript IPC latency — blog.persistent.info/2015/01/wkwebview-communication-latency
- WKWebView retain cycle via script message handler — tigi44.github.io
- Swift Forums: memory-mapped file discussion — forums.swift.org/t/what-s-the-recommended-way-to-memory-map-a-file/19113
- Swift Forums: String iteration performance — forums.swift.org/t/confused-by-string-iteration-performance/46723
- Slow app startup times (dylib analysis) — useyourloaf.com/blog/slow-app-startup-times
- Swift executable loading and startup performance on macOS (2025) — joyeecheung.github.io/blog/2025/01/11/executable-loading-and-startup-performance-on-macos

### Tertiary (LOW confidence)

- WKWebView pre-warm timing savings: 80–200ms range cited from community reports; Apple does not publish a benchmark. Treat as directionally correct, not precise. Validate with Instruments before implementing.

---

*Research completed: 2026-04-03*
*Ready for roadmap: yes*
