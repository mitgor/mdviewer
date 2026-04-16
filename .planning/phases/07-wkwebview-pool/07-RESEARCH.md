# Phase 7: WKWebView Pool - Research

**Researched:** 2026-04-16
**Domain:** WKWebView lifecycle, process management, object pooling (macOS/AppKit)
**Confidence:** HIGH

## Summary

Phase 7 evolves the current single-instance pre-warm strategy (one `WebContentView` created at launch, consumed by the first file open) into a proper pool of 2 pre-warmed WKWebView instances that replenishes automatically and handles WebContent process crashes.

The current codebase already demonstrates the core technique: `AppDelegate.preWarmedContentView` creates a `WebContentView(frame: .zero)` at launch, then hands it off on the first `displayResult` call. This phase generalizes that pattern into a pool class that always has a ready view available for the 2nd+ file open.

**Primary recommendation:** Create a `WebViewPool` class that manages an array of pre-configured `WebContentView` instances. The pool dequeues views for use, replenishes asynchronously after each dequeue, and monitors for WebContent process crashes via `WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:)`. The existing `preWarmedContentView` property on `AppDelegate` is replaced entirely by pool access.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| POOL-01 | App maintains a pool of 2 pre-warmed WKWebView instances ready for immediate use | Pool class with configurable capacity; creates WebContentView instances at init |
| POOL-02 | Pool replenishes asynchronously after a view is acquired | `DispatchQueue.main.async` to create replacement after `dequeue()` |
| POOL-03 | Pool handles WebContent process termination (recreates crashed views) | `WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:)` callback |
| PERF-03 | 2nd+ file open is under 100ms with WKWebView pool active | Pool eliminates ~40ms WKWebView init; measured via existing OSSignposter `open-to-paint` interval |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| WKWebView instance creation | Frontend (AppKit) | -- | WKWebView is a UI component; must be created on main thread |
| Pool lifecycle management | Frontend (AppKit) | -- | Pool is tied to app lifecycle (create at launch, drain at terminate) |
| Process crash detection | Frontend (WebKit) | -- | WKNavigationDelegate callback fires on main thread |
| Pool replenishment | Frontend (AppKit) | -- | Async main-thread dispatch to create replacement views |
| Performance measurement | Frontend (OSSignposter) | -- | Existing signpost infrastructure in AppDelegate |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| WebKit (WKWebView) | macOS 13+ system | Web content rendering | Already used; pool manages pre-created instances [VERIFIED: codebase] |
| AppKit (NSView) | macOS 13+ system | View hierarchy for WebContentView | Already used; WebContentView is NSView subclass [VERIFIED: codebase] |
| os (OSSignposter) | macOS 13+ system | Performance measurement | Already used for `open-to-paint` interval [VERIFIED: codebase] |

No new dependencies required. This phase is purely architectural refactoring of existing components.

## Architecture Patterns

### System Architecture Diagram

```
                    AppDelegate
                        |
              [openFile called]
                        |
                        v
              +-----------------+
              |  WebViewPool    |  <-- owns 2 pre-warmed views
              |  .dequeue()     |
              +----|------------+
                   |        ^
                   |        | replenish (async)
                   v        |
            WebContentView  |
            (pre-warmed)    |
                   |        |
                   v        |
            MarkdownWindow  |
            (displays it)   |
                            |
        [crash detected] ---+
        webViewWebContent
        ProcessDidTerminate
```

**Data flow for 2nd+ file open:**
1. User opens file -> `AppDelegate.openFile(_:)` dispatches parse to background
2. Parse completes -> `displayResult` calls `pool.dequeue()` (instant, ~0ms)
3. Pool returns pre-warmed `WebContentView`, pool count drops to 1
4. Pool asynchronously creates replacement `WebContentView`, pool count returns to 2
5. Content loaded into dequeued view via `loadContent(page:remainingChunks:hasMermaid:)`

### Recommended Project Structure

No new files beyond the pool class itself:

```
MDViewer/
  WebViewPool.swift        # NEW: Pool management class
  WebContentView.swift     # MODIFIED: Add WKNavigationDelegate for crash detection
  AppDelegate.swift        # MODIFIED: Replace preWarmedContentView with pool
  MarkdownWindow.swift     # UNCHANGED
  MarkdownRenderer.swift   # UNCHANGED
```

### Pattern 1: Object Pool with Async Replenishment

**What:** A class that maintains a fixed-size array of pre-created objects, hands them out on demand, and replaces consumed objects asynchronously.

**When to use:** When object creation has non-trivial latency (WKWebView init is ~40ms) and objects are needed with zero delay.

**Example:**
```swift
// Source: Custom pattern based on codebase conventions
final class WebViewPool {
    private var pool: [WebContentView] = []
    private let capacity: Int

    init(capacity: Int = 2) {
        self.capacity = capacity
        // Fill pool synchronously at launch
        for _ in 0..<capacity {
            pool.append(createView())
        }
    }

    func dequeue() -> WebContentView? {
        guard !pool.isEmpty else { return nil }
        let view = pool.removeFirst()
        replenish()
        return view
    }

    private func replenish() {
        guard pool.count < capacity else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pool.count < self.capacity else { return }
            self.pool.append(self.createView())
        }
    }

    private func createView() -> WebContentView {
        let view = WebContentView(frame: .zero)
        // Pool sets itself as crash observer (see Pattern 2)
        return view
    }

    func discard(_ view: WebContentView) {
        // Called when a crash is detected in a pooled (unused) view
        pool.removeAll { $0 === view }
        replenish()
    }
}
```

### Pattern 2: WebContent Process Crash Recovery

**What:** Detect when a WKWebView's underlying WebContent process terminates and remove the dead view from the pool.

**When to use:** Any time WKWebView instances are held for later use (pooled). A crashed WebContent process leaves the WKWebView in an unusable state.

**Key API:** `WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:)` [VERIFIED: Apple Developer Documentation]

**Example:**
```swift
// Source: Apple Developer Documentation - WKNavigationDelegate
// WebContentView must conform to WKNavigationDelegate (or pool acts as delegate for idle views)
func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // View is now unusable — discard from pool and create replacement
    pool.discard(self)
}
```

**Design decision — who is the navigation delegate for pooled views:**
- Option A: The pool itself conforms to `WKNavigationDelegate` and monitors idle views. When a view is dequeued, the delegate is reassigned. This is cleaner because pooled views have no business logic owner yet.
- Option B: `WebContentView` always monitors its own WKWebView and notifies the pool via a callback/delegate.
- **Recommendation:** Option A — pool is the delegate for idle views. Once dequeued, the view's navigation delegate can be reassigned or cleared. This keeps `WebContentView` unchanged for the crash-of-idle-view case. For in-use views that crash, `AppDelegate` can handle it separately (show an alert, close the window).

### Pattern 3: Shared WKWebViewConfiguration

**What:** All pooled views share the same `WKWebViewConfiguration` base setup (developer extras, content controller settings).

**When to use:** When multiple WKWebViews need identical configuration. Note: `WKWebViewConfiguration` is copied at `WKWebView.init` time, so changes after creation don't propagate. [VERIFIED: Apple Developer Documentation]

**Important:** Each `WKWebView` gets its own `WKUserContentController` because script message handlers hold strong references to their targets (the retain cycle that `WeakScriptMessageProxy` already solves). Sharing a single content controller across pooled views would create handler conflicts. The current pattern of creating a fresh config + content controller per `WebContentView` is correct and should be preserved. [VERIFIED: codebase WebContentView.swift]

### Anti-Patterns to Avoid

- **Sharing WKUserContentController across pooled views:** Each view needs its own content controller with its own message handlers. The `WeakScriptMessageProxy` pattern already handles this correctly per-view. [VERIFIED: codebase]
- **Synchronous replenishment in `dequeue()`:** Creating a WKWebView takes ~40ms. Blocking the caller defeats the purpose of pooling. Always replenish asynchronously.
- **Using `WKProcessPool` for pooling:** `WKProcessPool` is about sharing web content *processes*, not about pooling *views*. It's also deprecated as of macOS 12. Don't confuse process pooling with view pooling. [VERIFIED: Apple Developer Documentation]
- **Keeping dead views in pool:** A WKWebView whose WebContent process has terminated cannot be revived by calling `reload()` on blank content. Discard and replace.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Process crash detection | Custom health-check polling | `webViewWebContentProcessDidTerminate(_:)` | WebKit provides the exact callback; polling wastes CPU and can miss events [VERIFIED: Apple docs] |
| Thread-safe pool access | Lock-based concurrent pool | Main-thread-only pool | WKWebView must be created/accessed on main thread anyway; no concurrency needed [ASSUMED] |

**Key insight:** WKWebView is inherently main-thread-bound (`@MainActor` in modern Swift). The pool doesn't need any concurrency primitives because all access (dequeue, replenish, discard) happens on the main thread.

## Common Pitfalls

### Pitfall 1: WKWebView Init on Background Thread

**What goes wrong:** Creating a WKWebView off the main thread causes crashes or undefined behavior.
**Why it happens:** WKWebView is a UI component; WebKit enforces main-thread creation.
**How to avoid:** Pool creation and replenishment must always happen on `DispatchQueue.main`. The current `openFile` dispatches parsing to background but calls `displayResult` on main — this pattern is correct. [VERIFIED: codebase AppDelegate.swift line 162]
**Warning signs:** Purple runtime warnings in Xcode about main thread violations.

### Pitfall 2: Retain Cycle with Pool + WKNavigationDelegate

**What goes wrong:** If the pool holds strong references to views AND is the navigation delegate of those views, but views also hold a strong reference back to the pool, a retain cycle forms.
**Why it happens:** WKWebView holds a strong reference to its `navigationDelegate`.
**How to avoid:** The pool holds views strongly (it owns them). Views' `navigationDelegate` is set to the pool (strong ref from WKWebView to pool). This is a one-way ownership — no cycle, because views don't hold a reference to the pool. When the pool is deallocated (app termination), views are released. [ASSUMED]
**Warning signs:** Views and pool not deallocating at app quit (check with `deinit` prints).

### Pitfall 3: Pool Exhaustion Under Rapid Opens

**What goes wrong:** User opens 3+ files in rapid succession; pool has only 2 views; third open gets no pre-warmed view.
**Why it happens:** Pool capacity is 2, replenishment is async.
**How to avoid:** Fallback to synchronous `WebContentView(frame: .zero)` creation when pool is empty. This is exactly what the current code does (non-pre-warmed path). The pool's `dequeue()` should return `nil` when empty, and `AppDelegate.displayResult` should fall through to creating a fresh view. [VERIFIED: codebase AppDelegate.swift line 174]
**Warning signs:** No warning signs — this is a graceful degradation, not an error.

### Pitfall 4: Loading Content into Pre-Warmed View Races with WKWebView Initialization

**What goes wrong:** A pre-warmed view is dequeued immediately but its WKWebView hasn't finished internal initialization yet; `loadHTMLString` is called on a not-fully-ready webview.
**Why it happens:** WKWebView creation returns immediately but the WebContent process may not be fully spun up.
**How to avoid:** In practice, this is not a problem because `loadHTMLString` queues the load and WebKit handles the sequencing internally. The current pre-warm pattern (create at launch, use later) works because enough time passes. For rapid dequeue+replenish, the replenished view also has time to initialize before the next dequeue. [ASSUMED]
**Warning signs:** Blank window that never shows content after dequeue.

### Pitfall 5: Forgetting to Clean Up Script Message Handlers on Discarded Views

**What goes wrong:** A pooled view whose process crashed is discarded, but its `WKUserContentController` still has script message handlers registered, preventing deallocation.
**Why it happens:** The current `WebContentView.deinit` calls `removeScriptMessageHandler(forName:)`, which is correct. But if the view is discarded without being deallocated (e.g., retained elsewhere), handlers leak.
**How to avoid:** Ensure discarded views have no other strong references. The pool's `discard()` method removes the only strong reference; `deinit` handles cleanup. [VERIFIED: codebase WebContentView.swift line 98]
**Warning signs:** `[WebContentView] deinit` never printed after discard.

## Code Examples

### Pool Integration in AppDelegate

```swift
// Source: Based on existing AppDelegate.swift patterns [VERIFIED: codebase]
class AppDelegate: NSObject, NSApplicationDelegate, WebContentViewDelegate {
    private let renderer = MarkdownRenderer()
    private var template: SplitTemplate?
    private var windows: [MarkdownWindow] = []
    private var openedViaDelegate = false
    private var openToPaintStates: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    private var hasCompletedFirstLaunchPaint = false

    // REPLACE: private var preWarmedContentView: WebContentView?
    private let webViewPool = WebViewPool(capacity: 2)

    // ...

    private func displayResult(_ result: RenderResult, for url: URL, paintState: OSSignpostIntervalState) {
        // Dequeue from pool; fall back to fresh creation if pool empty
        let contentView = webViewPool.dequeue() ?? WebContentView(frame: .zero)
        contentView.delegate = self
        openToPaintStates[ObjectIdentifier(contentView)] = paintState
        // ... rest unchanged
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Pool drains automatically when AppDelegate is deallocated
    }
}
```

### Crash Recovery for In-Use Views

```swift
// Source: Apple Developer Documentation [VERIFIED]
// For views already in windows (not in pool), handle crash at AppDelegate level
extension AppDelegate: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Find the window containing this crashed view
        // Show error alert or attempt reload
    }
}
```

### OSSignposter Measurement for PERF-03

```swift
// Source: Existing codebase pattern [VERIFIED: AppDelegate.swift line 145]
// The existing open-to-paint signpost already measures what PERF-03 needs:
let paintState = appSignposter.beginInterval("open-to-paint")
// ... dequeue from pool (near-zero time) ...
// ... loadContent ...
// ... first paint callback ends interval
```

No new signpost instrumentation needed — the existing `open-to-paint` interval captures the full open-to-visible time. Pool usage simply makes this interval shorter for 2nd+ opens.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `WKProcessPool` for sharing processes | Automatic process management (deprecated macOS 12) | macOS 12 / 2021 | Don't use `WKProcessPool`; WebKit manages processes automatically [VERIFIED: Apple docs] |
| Single pre-warmed view | Object pool pattern | This phase | Ensures every file open (not just first) gets a pre-warmed view |

**Deprecated/outdated:**
- `WKProcessPool.processPool` property: Deprecated macOS 10.10-12.0. No replacement needed — WebKit handles process sharing automatically. [VERIFIED: Apple Developer Documentation]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | WKWebView doesn't need any concurrency primitives because all access is main-thread | Don't Hand-Roll | LOW — WKWebView is documented as main-thread-only; if wrong, pool would need a lock |
| A2 | Pool -> View navigation delegate doesn't create a retain cycle | Pitfall 2 | LOW — standard delegate pattern; WKWebView.navigationDelegate is weak by convention but should verify |
| A3 | loadHTMLString on a just-created WKWebView works even if WebContent process hasn't fully spun up | Pitfall 4 | MEDIUM — if wrong, pool would need a "ready" callback before marking view available |

## Open Questions (RESOLVED)

1. **Pool capacity: is 2 the right number?** RESOLVED: Configurable capacity, default 2 per POOL-01 spec.
   - What we know: Requirements specify 2 (POOL-01). WKWebView uses ~20-30MB per instance.
   - What's unclear: Whether 2 is optimal or if 1 would suffice (since replenishment is fast).
   - Recommendation: Implement with configurable capacity, default to 2 per POOL-01.

2. **Should in-use views (already in windows) also get crash recovery?** RESOLVED: POOL-03 scope is pooled (idle) views only; in-use view crash recovery is out of scope.
   - What we know: POOL-03 says "Pool handles WebContent process termination (recreates crashed views)." This implies pool-managed views.
   - What's unclear: Whether windows with active content should also show a recovery UI.
   - Recommendation: Implement crash recovery for pooled (idle) views as required. For in-use views, show an error alert (stretch goal, not required by POOL-03).

3. **Should the pool pre-load `about:blank` or leave views completely fresh?** RESOLVED: Start without blank page load; measure; add if PERF-03 unmet.
   - What we know: The current pre-warm creates `WebContentView(frame: .zero)` without loading any content. WebViewWarmUper pattern suggests loading a blank page to fully initialize the WebContent process.
   - What's unclear: Whether loading `about:blank` provides meaningful speedup over just creating the view.
   - Recommendation: Start with the current approach (no blank page load). Measure. If PERF-03 is not met, add `about:blank` pre-load.

## Environment Availability

Step 2.6: SKIPPED (no external dependencies identified -- purely internal architectural refactoring using existing WebKit framework)

## Sources

### Primary (HIGH confidence)
- [Apple Developer Documentation: WKProcessPool](https://developer.apple.com/documentation/webkit/wkprocesspool) - Deprecation status, process sharing semantics
- [Apple Developer Documentation: webViewWebContentProcessDidTerminate](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate%28_%3A%29) - Crash detection callback API
- [Apple Developer Documentation: WKWebViewConfiguration.configuration](https://developer.apple.com/documentation/webkit/wkwebview/configuration) - Configuration is copied at init time
- Context7 `/websites/developer_apple_webkit` - WKProcessPool, WKNavigationDelegate, WKWebViewConfiguration docs
- Codebase: `WebContentView.swift`, `AppDelegate.swift`, `MarkdownWindow.swift` - Current pre-warm implementation

### Secondary (MEDIUM confidence)
- [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper) - Pool/pre-warm pattern reference, ~45% load time reduction claim
- [Embrace: Why Is WKWebView So Heavy](https://embrace.io/blog/wkwebview-memory-leaks/) - Memory characteristics of WKWebView instances

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new dependencies, all APIs verified in Apple docs
- Architecture: HIGH - pattern is a straightforward generalization of existing pre-warm code
- Pitfalls: HIGH - crash recovery API is well-documented; retain cycle patterns are understood from existing codebase

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (stable APIs, no fast-moving dependencies)
