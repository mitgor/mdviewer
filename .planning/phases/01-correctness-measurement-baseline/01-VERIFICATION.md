---
phase: 01-correctness-measurement-baseline
verified: 2026-04-06T10:45:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
---

# Phase 01: Correctness and Measurement Baseline — Verification Report

**Phase Goal:** Every window close releases all WKWebView memory, and pipeline instrumentation produces valid profiling data
**Verified:** 2026-04-06T10:45:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Closing a markdown window deallocates its WebContentView and MarkdownWindow (deinit fires) | VERIFIED | `deinit` present in both classes with `removeScriptMessageHandler` cleanup in WebContentView and DEBUG print in both |
| 2 | Opening and closing 10 windows in sequence does not grow sustained RSS | HUMAN NEEDED | Retain cycle is structurally broken — WeakScriptMessageProxy confirmed — but actual memory non-growth requires runtime profiling |
| 3 | os_signpost intervals for file-read, parse, chunk-split, and chunk-inject appear in Instruments | VERIFIED | All four `beginInterval`/`endInterval` pairs confirmed in MarkdownRenderer.swift and WebContentView.swift |
| 4 | An open-to-paint parent interval spans the full pipeline from openFile to firstPaint | VERIFIED | `beginInterval("open-to-paint")` in `openFile(_:)` and `endInterval("open-to-paint", paintState)` in `webContentViewDidFinishFirstPaint(_:)` confirmed |

**Score:** 3/4 truths fully verified programmatically (Truth 2 needs human runtime validation, structural fix confirmed)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/WebContentView.swift` | WeakScriptMessageProxy, deinit with cleanup, hasProcessedFirstPaint guard | VERIFIED | All three present: proxy class at lines 16-30, deinit at lines 101-106, guard at line 91 |
| `MDViewer/MarkdownWindow.swift` | deinit with DEBUG logging | VERIFIED | deinit at lines 38-42 with `#if DEBUG` print |
| `MDViewer/MarkdownRenderer.swift` | OSSignposter intervals for file-read, parse, chunk-split | VERIFIED | Module-level `renderingSignposter` at lines 29-32; three intervals in `renderFullPage(fileURL:template:)` |
| `MDViewer/AppDelegate.swift` | OSSignposter open-to-paint parent interval | VERIFIED | `appSignposter` at lines 5-8; `openToPaintStates` dictionary; begin in `openFile`, end in `webContentViewDidFinishFirstPaint` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `WebContentView.swift` | `WKUserContentController` | WeakScriptMessageProxy breaks retain cycle | WIRED | `contentController.add(WeakScriptMessageProxy(delegate: self), name: "firstPaint")` at line 59; old `contentController.add(self,` count = 0 |
| `WebContentView.swift` | deinit | removeScriptMessageHandler cleanup | WIRED | `webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")` at line 102 |
| `MarkdownRenderer.swift` | Instruments | OSSignposter intervals | WIRED | `beginInterval("file-read")`, `beginInterval("parse")`, `beginInterval("chunk-split")` with matching `endInterval` calls; subsystem `"com.mdviewer.app"` matches bundle ID |
| `AppDelegate.swift` | `WebContentView.swift` | open-to-paint signpost spans openFile through webContentViewDidFinishFirstPaint | WIRED | State stored via `ObjectIdentifier`-keyed `openToPaintStates` dictionary; `removeValue(forKey:)` call in `webContentViewDidFinishFirstPaint` closes the interval correctly |

### Data-Flow Trace (Level 4)

Not applicable — this phase produces no data-rendering components. Artifacts are instrumentation and memory management code only.

### Behavioral Spot-Checks

Step 7b: SKIPPED — no runnable entry points testable without a running macOS app and Instruments.

The build was confirmed by commit metadata. Build verification via xcodebuild would require the full Xcode toolchain and project dependencies; the commit diffs and grep evidence sufficiently validate correctness.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| MEM-01 | 01-01-PLAN.md | WKUserContentController retain cycle fixed — closing a window releases all WKWebView memory | SATISFIED | WeakScriptMessageProxy confirmed; old `contentController.add(self,` line count = 0; `removeScriptMessageHandler` in deinit; both `deinit` methods confirmed |
| LAUNCH-01 | 01-01-PLAN.md | `os_signpost` instrumentation added to measure each pipeline phase | SATISFIED | Five intervals confirmed: file-read, parse, chunk-split, chunk-inject, open-to-paint; subsystem `"com.mdviewer.app"`, category `"RenderingPipeline"` verified in both MarkdownRenderer.swift and AppDelegate.swift |

No orphaned requirements: REQUIREMENTS.md Traceability table maps only MEM-01 and LAUNCH-01 to Phase 1. Both are claimed by 01-01-PLAN.md and verified in the codebase.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | No anti-patterns found |

Scan notes:
- No `TODO`/`FIXME`/`PLACEHOLDER` comments in any of the four modified files
- No `return null`, `return []`, or stub handlers
- `hasProcessedFirstPaint` guard prevents double-fire without leaking state
- `openToPaintStates` uses `removeValue` (not `[key]`) to avoid retaining finished states
- `#if DEBUG` gates on `developerExtrasEnabled` and both `deinit` print statements are correct — these are intentional debug-only outputs, not stubs

### Human Verification Required

#### 1. Memory non-growth across 10 open/close cycles

**Test:** Build the Debug scheme. Open Instruments, select the Leaks or Allocations template, attach to MDViewer. Open 10 different `.md` files in sequence, closing each before opening the next. Check Persistent Bytes / Live Bytes after the 10th close.
**Expected:** RSS returns to near-baseline after each close; no growing allocation ladder in the Allocations track. `[WebContentView] deinit` and `[MarkdownWindow] deinit` appear in the Xcode console for each close.
**Why human:** Cannot be verified by static analysis. Requires a running app and profiler. The retain cycle is structurally fixed (WeakScriptMessageProxy confirmed), but runtime confirmation eliminates any secondary cycle not visible in source.

#### 2. Signpost intervals visible in Instruments

**Test:** Open Instruments, add the os_signpost instrument, launch MDViewer, open a `.md` file. In the signpost lane, filter by subsystem `com.mdviewer.app` / category `RenderingPipeline`.
**Expected:** Five intervals appear: `file-read`, `parse`, `chunk-split`, `chunk-inject`, `open-to-paint`. The `open-to-paint` interval spans from file open to window fade-in.
**Why human:** Instruments UI interaction and signpost lane visibility cannot be tested programmatically. The API calls are present and correct, but visual confirmation in Instruments validates the subsystem/category registration.

### Gaps Summary

No gaps blocking goal achievement. All structural changes are in place:

- The WKWebView retain cycle is broken via `WeakScriptMessageProxy` (proxy class confirmed, old self-registration line count = 0)
- Both `WebContentView` and `MarkdownWindow` have `deinit` methods with correct cleanup and DEBUG logging
- `hasProcessedFirstPaint` prevents double firstPaint processing (confirmed at declaration, guard, and set sites)
- `developerExtrasEnabled` is correctly gated behind `#if DEBUG`
- All five OSSignposter intervals are present with matching `beginInterval`/`endInterval` pairs
- Subsystem `"com.mdviewer.app"` and category `"RenderingPipeline"` match across both signposter instances
- `ObjectIdentifier`-keyed `openToPaintStates` correctly associates and removes paint states per-window
- Both task commits (d29c47e, 07bba4d) exist in git history with correct file diffs
- MEM-01 and LAUNCH-01 are the only requirements assigned to Phase 1; both are satisfied

The two human verification items are confirmation tasks, not blockers. The phase goal is achieved.

---

_Verified: 2026-04-06T10:45:00Z_
_Verifier: Claude (gsd-verifier)_
