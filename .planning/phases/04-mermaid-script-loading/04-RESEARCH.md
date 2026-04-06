# Phase 4: Mermaid Script Loading - Research

**Researched:** 2026-04-06
**Domain:** WKWebView resource loading, JavaScript IPC optimization
**Confidence:** HIGH

## Summary

The current implementation in `WebContentView.loadAndInitMermaid()` reads the entire 3MB `mermaid.min.js` file into a Swift `String`, then sends it over the WebKit IPC bridge via `evaluateJavaScript(js)`. This is wasteful: every window with Mermaid diagrams pays a ~3MB IPC serialization cost, and WebKit's JavaScript context must parse the source from a string literal rather than loading it as a proper script resource.

The fix is straightforward. The app already sets `baseURL` to `Bundle.main.resourceURL` when calling `loadHTMLString`, which means `<script src="mermaid.min.js">` tags resolve correctly to the bundled file. Instead of injecting the JS source as a string, we inject a `<script>` DOM element whose `src` points to the local bundle file. WebKit loads it directly from disk via the file: URL, bypassing the IPC bridge entirely.

The change touches two files: `WebContentView.swift` (replace `evaluateJavaScript(js)` with a small JS snippet that creates a `<script src>` tag) and `template.html` (remove the comment about evaluateJavaScript loading, no functional change needed). The static `mermaidJS` cache and `mermaidJSLoaded` flag become unnecessary and should be removed.

**Primary recommendation:** Replace the `evaluateJavaScript(mermaidSource)` call with a small `evaluateJavaScript` that creates a `<script>` element with `src="mermaid.min.js"`, listens for its `onload` event, and then calls `window.initMermaid()`.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MEM-03 | Mermaid.js loaded via `<script src>` in template, not 3MB `evaluateJavaScript` bridge call | Core finding: replace evaluateJavaScript(fullSource) with DOM-injected script tag using src attribute; baseURL already resolves correctly |
</phase_requirements>

## Architecture Patterns

### Current Flow (problematic)

```
1. WebContentView.loadAndInitMermaid() called after first paint
2. Reads mermaid.min.js (3,164,970 bytes) from bundle into String (once, cached)
3. Calls webView.evaluateJavaScript(js) — sends ~3MB over IPC per window
4. On completion, calls webView.evaluateJavaScript("window.initMermaid()")
```

### Target Flow

```
1. WebContentView.loadAndInitMermaid() called after first paint
2. Calls evaluateJavaScript with ~150 bytes of JS that creates a <script> element
3. Script element has src="mermaid.min.js" — WebKit loads directly from disk
4. Script onload callback calls window.initMermaid()
```

### Key Implementation Pattern

```swift
// Source: WKWebView loadHTMLString baseURL documentation
// The app already uses Bundle.main.resourceURL as baseURL (WebContentView.swift:79-80)
// so relative src paths in script tags resolve to the bundle's Resources directory.

private func loadAndInitMermaid() {
    let js = """
    (function() {
        var s = document.createElement('script');
        s.src = 'mermaid.min.js';
        s.onload = function() { window.initMermaid(); };
        document.head.appendChild(s);
    })()
    """
    webView.evaluateJavaScript(js)
}
```

### What Gets Removed

| Item | Location | Reason |
|------|----------|--------|
| `private static var mermaidJS: String?` | WebContentView.swift:42 | No longer reading file into String |
| `private static var mermaidJSLoaded = false` | WebContentView.swift:43 | No lazy-load caching needed |
| File-reading block in `loadAndInitMermaid` | WebContentView.swift:209-215 | Replaced by script src |
| `evaluateJavaScript(js)` with full source | WebContentView.swift:219 | Replaced by script-tag injection |

### Anti-Patterns to Avoid

- **Do NOT add a static `<script src="mermaid.min.js">` to template.html**: This would load the 3MB script for ALL documents, even those without Mermaid diagrams. The conditional loading (only when `hasMermaid == true`) must be preserved.
- **Do NOT use `loadFileURL` instead of `loadHTMLString`**: The app uses `loadHTMLString` with `baseURL` for good reason (template loaded before delegate fires). Changing the loading mechanism is out of scope and risky.
- **Do NOT use `callAsyncJavaScript` for the script injection**: The small injection snippet is a fire-and-forget DOM manipulation, not a data-passing operation. `evaluateJavaScript` is appropriate here since there are no user-data arguments to escape.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Script loading from bundle | Custom file: URL construction | `<script src="mermaid.min.js">` with existing baseURL | WebKit resolves relative URLs against baseURL automatically |
| Script load completion detection | Polling or setTimeout | `script.onload` callback | Native browser event, reliable and immediate |
| Mermaid availability check | `typeof mermaid` polling loop | `onload` event on script element | Guaranteed to fire after script execution |

## Common Pitfalls

### Pitfall 1: Script onload vs onerror
**What goes wrong:** Script fails to load (e.g., file missing from bundle) and `initMermaid` never fires, leaving "Loading diagram..." placeholders forever.
**Why it happens:** No error handling on script load failure.
**How to avoid:** Add `s.onerror` handler that replaces placeholders with the raw mermaid source code (same fallback as the current `catch` in `renderNextDiagram`).
**Warning signs:** Mermaid placeholders showing indefinitely with pulsing animation.

### Pitfall 2: Multiple script injections
**What goes wrong:** If two windows both have Mermaid content and fire `loadAndInitMermaid` around the same time, each WKWebView gets its own script injection -- but that is correct since each WKWebView has its own JS context. No actual pitfall here, but worth noting: the static cache (`mermaidJS`, `mermaidJSLoaded`) was only useful for the old approach. Each WKWebView will load mermaid.min.js independently from disk, which is fine -- WebKit handles file caching at the process level.

### Pitfall 3: baseURL must be set correctly
**What goes wrong:** `<script src="mermaid.min.js">` fails to resolve if baseURL is nil or wrong.
**Why it happens:** The baseURL is set in `loadContent` (line 79-80 of WebContentView.swift).
**How to avoid:** This is already correct: `Bundle.main.resourceURL ?? Bundle.main.bundleURL`. No change needed.
**Warning signs:** JavaScript console error "Failed to load resource" in Web Inspector.

### Pitfall 4: Forgetting to update template.html comment
**What goes wrong:** The comment on line 270 (`<!-- mermaid.min.js loaded on demand via evaluateJavaScript -->`) becomes misleading.
**How to avoid:** Update or remove the comment to reflect the new script-src approach.

## Code Examples

### Complete replacement for loadAndInitMermaid

```swift
// Replaces the current loadAndInitMermaid() in WebContentView.swift
// No static properties needed — WebKit loads from disk via src attribute
private func loadAndInitMermaid() {
    let js = """
    (function() {
        var s = document.createElement('script');
        s.src = 'mermaid.min.js';
        s.onload = function() { window.initMermaid(); };
        s.onerror = function() {
            var els = document.querySelectorAll('.mermaid-placeholder');
            els.forEach(function(el) {
                var pre = document.createElement('pre');
                var code = document.createElement('code');
                code.textContent = el.getAttribute('data-mermaid-source') || 'Mermaid failed to load';
                pre.appendChild(code);
                el.replaceWith(pre);
            });
        };
        document.head.appendChild(s);
    })()
    """
    webView.evaluateJavaScript(js)
}
```

### Verification approach (Instruments)

To verify MEM-03, use Instruments with the "JavaScript and WebKit" or "Allocations" template:
1. Open a markdown file with Mermaid diagrams
2. Look for IPC message size in the WebKit process
3. The largest `evaluateJavaScript` call should be < 1KB (the script-injection snippet), not ~3MB

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `evaluateJavaScript(fullSource)` for large JS | `<script src>` tag injection | Always been the correct approach for WKWebView | Avoids multi-MB IPC serialization overhead |

## Open Questions

1. **WKWebView process-level caching of script src**
   - What we know: Each WKWebView has its own JS context, so mermaid global won't persist across windows
   - What's unclear: Whether WebKit's content process caches the parsed file: URL resource across WKWebView instances in the same process pool
   - Recommendation: Not critical -- even without caching, loading 3MB from local SSD is < 10ms. The win is eliminating IPC, not disk I/O.

## Sources

### Primary (HIGH confidence)
- [Apple Developer Documentation: loadHTMLString(_:baseURL:)](https://developer.apple.com/documentation/webkit/wkwebview/1415004-loadhtmlstring) -- confirms baseURL is used for relative URL resolution
- Direct code inspection of WebContentView.swift, template.html, mermaid.min.js (3,164,970 bytes)

### Secondary (MEDIUM confidence)
- [Hacking with Swift: loadHTMLString](https://www.hackingwithswift.com/example-code/uikit/how-to-load-a-html-string-into-a-wkwebview-or-uiwebview-loadhtmlstring) -- confirms baseURL enables local resource loading

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new dependencies, using existing WKWebView APIs
- Architecture: HIGH - direct code inspection, minimal change surface
- Pitfalls: HIGH - well-understood browser script loading semantics

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable -- WKWebView APIs are mature)
