---
phase: 07-wkwebview-pool
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - MDViewer/WebViewPool.swift
  - MDViewer/WebContentView.swift
  - MDViewer/AppDelegate.swift
  - MDViewerTests/WebViewPoolTests.swift
findings:
  critical: 0
  warning: 4
  info: 3
  total: 7
status: issues_found
---

# Phase 07: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

This phase introduced `WebViewPool` for pre-warming `WebContentView` instances and wired it into `AppDelegate.displayResult`. The pool design is sound: main-thread-only access eliminates the need for synchronization, crash detection via `WKNavigationDelegate` is delegated to the pool for idle views, and replenishment is safely guarded against over-filling.

Four warnings and three info-level issues were found. The most significant is a signpost interval leak in `WebContentView.injectRemainingChunks` where a `[weak self]` early-exit can prevent the `endInterval` call from ever firing on the last chunk. A crash in an active (non-pooled) WKWebView process also goes completely undetected and unannounced to the user. Both are correctness issues that should be addressed before shipping.

---

## Warnings

### WR-01: Signpost interval leaks when `self` is deallocated during chunk injection

**File:** `MDViewer/WebContentView.swift:120-144`

**Issue:** `injectRemainingChunks` captures `chunkInjectState` across multiple `DispatchQueue.main.asyncAfter` closures. The `endInterval` call is guarded inside the `completionHandler` of `callAsyncJavaScript`, which is only invoked when `self` is still alive (the `[weak self]` guard on line 131 causes an early return if `self` is nil). If the window is closed before the last async block fires — which is plausible for documents with many chunks — `self` becomes nil, `callAsyncJavaScript` is never called for that iteration, the completion handler never runs, and `renderingSignposter.endInterval("chunk-inject", chunkInjectState)` is never called. The signpost interval is leaked for the lifetime of the process.

**Fix:** End the interval outside the `[weak self]` guard, or capture `chunkInjectState` directly in the completion closure without going through `self`:

```swift
private func injectRemainingChunks() {
    guard !remainingChunks.isEmpty else { return }

    let chunkInjectState = renderingSignposter.beginInterval("chunk-inject")
    let chunks = remainingChunks
    let chunkCount = chunks.count
    remainingChunks = []

    for (index, chunk) in chunks.enumerated() {
        let delay = Double(index) * 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                // self gone — end interval on the last slot to avoid leaking
                if index == chunkCount - 1 {
                    renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                }
                return
            }
            self.webView.callAsyncJavaScript(
                "window.appendChunk(html)",
                arguments: ["html": chunk],
                in: nil,
                in: .page,
                completionHandler: { _ in
                    if index == chunkCount - 1 {
                        renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                    }
                }
            )
        }
    }
}
```

---

### WR-02: Active-window web-process crash is silent — user sees a blank window with no feedback

**File:** `MDViewer/WebViewPool.swift:63-69`, `MDViewer/WebContentView.swift:101-103`

**Issue:** Crash detection via `WKNavigationDelegate.webViewWebContentProcessDidTerminate` is only wired for views that are currently idle in the pool. When `dequeue()` hands a view to `displayResult`, the navigation delegate is cleared (`setNavigationDelegate(nil)`, line 23). If the WKWebView web process subsequently crashes during active display (out-of-memory, renderer hang), no delegate receives the termination callback, no recovery is attempted, and the user is left with a permanent blank window. This is a silent failure with no path to recovery or diagnostic.

**Fix:** `AppDelegate` (or `MarkdownWindow`) should set itself — or a dedicated object — as the navigation delegate after dequeue, implementing `webViewWebContentProcessDidTerminate` to show an error state or attempt a reload:

```swift
// In AppDelegate.displayResult, after dequeue:
contentView.setNavigationDelegate(self) // AppDelegate conforms to WKNavigationDelegate

// Add extension AppDelegate: WKNavigationDelegate
extension AppDelegate: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Find the window with this crashed view and show an error
        guard let window = windows.first(where: { $0.contentViewWrapper.ownsWebView(webView) }) else { return }
        // Show alert or inject error HTML
    }
}
```

---

### WR-03: `ensureTemplateLoaded()` unconditionally rebuilds the menu bar

**File:** `MDViewer/AppDelegate.swift:124-129`

**Issue:** `ensureTemplateLoaded` is called from both `application(_:open:)` (line 58) and `application(_:openFile:)` (line 66). If `template` is nil at that point, it calls both `loadTemplate()` and `setupMenu()`. `loadTemplate()` correctly guards with `guard template == nil else { return }`, but `setupMenu()` has no such guard — it rebuilds and replaces `NSApp.mainMenu` from scratch every time `ensureTemplateLoaded` finds `template == nil`. In practice this path is unlikely in normal use (template loads at launch), but if `applicationDidFinishLaunching` fails to load the template (e.g., bad bundle), opening a file will rebuild the menu on each call. More importantly, the code's intent is unclear: why should ensuring the template is loaded also rebuild the menu?

**Fix:** Extract the menu setup guard into `setupMenu()` itself, or remove the `setupMenu()` call from `ensureTemplateLoaded`:

```swift
private func ensureTemplateLoaded() {
    guard template == nil else { return }
    loadTemplate()
    // setupMenu() is NOT needed here — menu was already set up at launch
}
```

---

### WR-04: `hasProcessedFirstPaint` is never reset between document loads on a reused pool view

**File:** `MDViewer/WebContentView.swift:40`, `MDViewer/WebContentView.swift:86-94`

**Issue:** `hasProcessedFirstPaint` is an instance property initialized to `false`. When a view is dequeued from the pool and reused via `loadContent(page:remainingChunks:hasMermaid:)`, `hasProcessedFirstPaint` retains its value from any previous load. If the pre-warmed view's blank page happened to fire a `firstPaint` message (which it will not in the current template, but is a fragile assumption), the flag would be `true` on reuse and the real first-paint callback would be silently dropped — no chunks injected, no Mermaid loaded, no window fade-in triggered. There is no reset in `loadContent`.

**Fix:** Reset transient per-load state at the top of `loadContent`:

```swift
func loadContent(page: String, remainingChunks: [String], hasMermaid: Bool) {
    self.remainingChunks = remainingChunks
    self.hasMermaid = hasMermaid
    self.hasProcessedFirstPaint = false  // reset for this load
    let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    webView.loadHTMLString(page, baseURL: resourceURL)
}
```

---

## Info

### IN-01: `documentTitle` property is declared but never read or written

**File:** `MDViewer/WebContentView.swift:147`

**Issue:** `private var documentTitle: String = ""` is declared between the pool-support methods and `printContent`. It is never assigned to or read in any method in the file. This is dead code.

**Fix:** Remove the declaration. If a title is needed for printing, it is already passed as a parameter to `printContent(title:)` and `exportPDF(filename:)`.

---

### IN-02: `AppDelegate` is not `final` — inconsistent with project convention

**File:** `MDViewer/AppDelegate.swift:10`

**Issue:** The project's established convention (documented in CLAUDE.md) is that all concrete classes not designed for subclassing are declared `final`. Every other class in the project (`MarkdownRenderer`, `MarkdownWindow`, `WebContentView`, `WebViewPool`) is `final`. `AppDelegate` is not.

**Fix:**

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, WebContentViewDelegate {
```

---

### IN-03: `evaluateJavaScript` calls in `toggleMonospace` and `loadAndInitMermaid` discard errors silently

**File:** `MDViewer/WebContentView.swift:81`, `MDViewer/WebContentView.swift:237`

**Issue:** Both calls use the no-completion-handler overload of `evaluateJavaScript`. If JavaScript evaluation fails (page not yet loaded, JS exception), the failure is silently discarded with no diagnostic. While this is acceptable for fire-and-forget UI actions, it makes debugging Mermaid load failures harder in production.

**Fix:** Add completion handlers in DEBUG builds at minimum:

```swift
#if DEBUG
webView.evaluateJavaScript(js) { _, error in
    if let error { print("[WebContentView] Mermaid injection failed: \(error)") }
}
#else
webView.evaluateJavaScript(js)
#endif
```

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
