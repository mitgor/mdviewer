---
phase: 04-mermaid-script-loading
verified: 2026-04-06T22:15:00Z
status: passed
score: 3/3 must-haves verified
re_verification: false
---

# Phase 04: Mermaid Script-Src Injection Verification Report

**Phase Goal:** Mermaid diagrams render without a 3MB IPC bridge call per window
**Verified:** 2026-04-06T22:15:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A markdown file with Mermaid diagrams renders correctly with diagrams visible | ✓ VERIFIED | `loadAndInitMermaid()` injects a script element that loads `mermaid.min.js` via `s.src`, then calls `window.initMermaid()` via `s.onload`. `initMermaid()` is defined in `template.html` and drives sequential diagram rendering. Error path via `s.onerror` degrades gracefully. |
| 2 | No multi-megabyte evaluateJavaScript IPC call occurs during Mermaid initialization | ✓ VERIFIED | Static properties `private static var mermaidJS: String?` and `private static var mermaidJSLoaded` are both absent (grep count: 0). The `evaluateJavaScript` call in `loadAndInitMermaid()` now carries ~350 bytes (DOM snippet), not the 3MB file contents. `String(contentsOf:)` absent from `WebContentView.swift` (grep count: 0). |
| 3 | Windows without Mermaid content do not load mermaid.min.js at all | ✓ VERIFIED | `loadAndInitMermaid()` is called only inside `if hasMermaid { ... }` at line 91-93. The `hasMermaid` flag is set from `RenderResult.hasMermaid` passed in `loadContent(page:remainingChunks:hasMermaid:)`. Non-Mermaid documents never invoke the script injection. |

**Score:** 3/3 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/WebContentView.swift` | Script-src Mermaid loading without static cache | ✓ VERIFIED | Contains `document.createElement('script')` (line 207). Static `mermaidJS`/`mermaidJSLoaded` properties removed. `loadAndInitMermaid()` replaced in full. |
| `MDViewer/Resources/template.html` | Updated comment reflecting script-src loading | ✓ VERIFIED | Line 270: `<!-- mermaid.min.js loaded on demand via script-src injection from WebContentView -->`. Old `evaluateJavaScript` comment absent (grep count: 0). |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `MDViewer/WebContentView.swift` | `mermaid.min.js` | DOM-injected script element with src attribute | ✓ WIRED | Line 208: `s.src = 'mermaid.min.js';` — resolves against `baseURL = Bundle.main.resourceURL` set in `loadContent`. `mermaid.min.js` confirmed present at `MDViewer/Resources/mermaid.min.js` (3.0 MB). |
| script `onload` | `window.initMermaid()` | onload callback on injected script element | ✓ WIRED | Line 209: `s.onload = function() { window.initMermaid(); };` — `window.initMermaid` is defined in `template.html` (line 289) and drives sequential `mermaid.render()` calls on all `.mermaid-placeholder` elements. |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase modifies a loading mechanism (IPC path), not a data-rendering component. There is no state variable rendered to DOM by `WebContentView.swift` itself; rendering occurs inside the WKWebView process after Mermaid.js executes. The flow is: script injected -> WebKit loads file from disk -> `initMermaid()` called -> `mermaid.render()` called per placeholder. The upstream source (`mermaid.min.js`) is a real 3MB bundled file, not a stub.

---

### Behavioral Spot-Checks

Step 7b: SKIPPED — changes affect WKWebView internals (script injection at runtime). Correct behavior requires a running macOS app with a rendered Mermaid document. Routed to human verification below.

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| MEM-03 | 04-01-PLAN.md | Mermaid.js loaded via script src, not 3MB evaluateJavaScript bridge call | ✓ SATISFIED | `loadAndInitMermaid()` sends ~350-byte DOM snippet; static mermaidJS cache removed; `s.src = 'mermaid.min.js'` uses WebKit disk load. REQUIREMENTS.md marks MEM-03 complete, Phase 4. |

No orphaned requirements: REQUIREMENTS.md maps only MEM-03 to Phase 4, which is the sole requirement declared in `04-01-PLAN.md`.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | None found | — | — |

No TODO, FIXME, placeholder, empty return, or hardcoded empty data patterns found in either modified file.

---

### Human Verification Required

#### 1. Mermaid Diagram Renders in a Live Window

**Test:** Open a `.md` file containing a fenced `mermaid` code block (e.g., a simple flowchart). Observe the window after it loads.
**Expected:** The mermaid placeholder (pulsing grey box) is replaced by a rendered SVG diagram within ~1-2 seconds of first paint.
**Why human:** Script injection and `mermaid.render()` execute inside WKWebView at runtime; cannot be verified with grep or static analysis.

#### 2. Non-Mermaid Document Does Not Load mermaid.min.js

**Test:** Open a `.md` file with no Mermaid blocks. In Safari Web Inspector (or WKWebView devtools with `developerExtrasEnabled`), check the Network tab for any request to `mermaid.min.js`.
**Expected:** No network/file request for `mermaid.min.js` appears.
**Why human:** The `hasMermaid` gate is code-verified, but confirming the absence of a disk load requires runtime observation.

#### 3. Mermaid Load Failure Degrades Gracefully

**Test:** Temporarily rename `mermaid.min.js` in the built `.app` bundle and open a Mermaid-containing file.
**Expected:** Mermaid placeholder elements are replaced with `<pre><code>` blocks showing the raw diagram source. No crash, no spinner left behind.
**Why human:** `s.onerror` path requires intentionally breaking the bundled file at runtime.

---

### Gaps Summary

No gaps. All three observable truths verified, both artifacts confirmed substantive and wired, both key links confirmed present, MEM-03 fully satisfied. The only open items require runtime execution in a macOS window (human verification).

---

_Verified: 2026-04-06T22:15:00Z_
_Verifier: Claude (gsd-verifier)_
