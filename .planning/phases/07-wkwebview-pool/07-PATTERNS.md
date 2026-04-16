# Phase 7: WKWebView Pool - Pattern Map

**Mapped:** 2026-04-16
**Files analyzed:** 3 (1 new, 2 modified)
**Analogs found:** 3 / 3

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `MDViewer/WebViewPool.swift` | service (pool manager) | request-response | `MDViewer/AppDelegate.swift` (preWarmedContentView pattern) | role-match |
| `MDViewer/AppDelegate.swift` | controller (app coordinator) | request-response | self (current implementation) | exact |
| `MDViewer/WebContentView.swift` | component (view) | event-driven | self (current implementation) | exact |

## Pattern Assignments

### `MDViewer/WebViewPool.swift` (NEW - service/pool, request-response)

**Analog:** `MDViewer/AppDelegate.swift` lines 17, 26, 47-48, 168-175

This is a new file. It should follow the project's class conventions: `final class`, `private` for internals, `[weak self]` in closures, `#if DEBUG` for diagnostic prints.

**Imports pattern** (match project style -- minimal, alphabetical by convention):
```swift
import Cocoa
import WebKit
```

**Class declaration pattern** (from `MarkdownRenderer.swift` line 33, `WebContentView.swift` line 9):
```swift
final class WebViewPool {
    // All classes that are not designed for subclassing use `final`
}
```

**Pre-warm creation pattern** (from `AppDelegate.swift` lines 17, 26):
```swift
// Current single-instance pre-warm -- pool generalizes this
private var preWarmedContentView: WebContentView?
// ...
preWarmedContentView = WebContentView(frame: .zero)
```

**Dequeue + fallback pattern** (from `AppDelegate.swift` lines 169-175):
```swift
// Current consume-once pattern -- pool replaces this with repeatable dequeue
let contentView: WebContentView
if let preWarmed = preWarmedContentView {
    contentView = preWarmed
    preWarmedContentView = nil  // Only first file gets pre-warmed view
} else {
    contentView = WebContentView(frame: .zero)
}
```

**Async dispatch pattern** (from `AppDelegate.swift` lines 30-37):
```swift
// [weak self] in all closures that capture self
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    // ... work ...
}
```

**Cleanup pattern** (from `AppDelegate.swift` lines 47-49):
```swift
func applicationWillTerminate(_ notification: Notification) {
    preWarmedContentView = nil
}
```

**Deinit debug pattern** (from `WebContentView.swift` lines 97-102, `MarkdownWindow.swift` lines 54-58):
```swift
deinit {
    #if DEBUG
    print("[WebViewPool] deinit - \(ObjectIdentifier(self))")
    #endif
}
```

**WKNavigationDelegate for crash detection** (new capability, no existing analog -- use Apple API directly):
```swift
// Pool conforms to WKNavigationDelegate for idle (pooled) views
extension WebViewPool: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Discard crashed view, replenish
    }
}
```

Note: To set the pool as navigation delegate of pooled WKWebViews, the pool needs access to `WebContentView.webView`. Currently `webView` is `private`. Either:
- Add an internal accessor on `WebContentView` (e.g., `var navigationDelegate` passthrough), or
- Have `WebContentView` itself detect crashes and notify via a callback.

The research recommends Option A (pool is delegate for idle views). The simplest implementation: add a method on `WebContentView` like `func setNavigationDelegate(_ delegate: WKNavigationDelegate?)` that forwards to the internal `webView.navigationDelegate`.

---

### `MDViewer/AppDelegate.swift` (MODIFIED - controller, request-response)

**Analog:** self (current implementation)

**Changes needed:**

1. **Replace property** (line 17):
```swift
// BEFORE:
private var preWarmedContentView: WebContentView?

// AFTER:
private let webViewPool = WebViewPool(capacity: 2)
```

2. **Replace dequeue in displayResult** (lines 168-175):
```swift
// BEFORE:
let contentView: WebContentView
if let preWarmed = preWarmedContentView {
    contentView = preWarmed
    preWarmedContentView = nil
} else {
    contentView = WebContentView(frame: .zero)
}

// AFTER:
let contentView = webViewPool.dequeue() ?? WebContentView(frame: .zero)
```

3. **Remove pre-warm creation** (line 26):
```swift
// REMOVE:
preWarmedContentView = WebContentView(frame: .zero)
// Pool handles this in its init
```

4. **Update terminate** (lines 47-49):
```swift
// BEFORE:
func applicationWillTerminate(_ notification: Notification) {
    preWarmedContentView = nil
}

// AFTER: Pool drains automatically when AppDelegate is deallocated.
// Can remove or keep empty for clarity.
```

---

### `MDViewer/WebContentView.swift` (MODIFIED - component, event-driven)

**Analog:** self (current implementation)

**Changes needed:** Expose a way for `WebViewPool` to set the navigation delegate on the internal `webView` for crash detection of idle pooled views.

**Current access control pattern** (line 36):
```swift
private let webView: WKWebView
```

**Proposed addition** (follows project convention of methods over property exposure):
```swift
/// Allow external crash-detection delegate for pooled views.
func setNavigationDelegate(_ delegate: WKNavigationDelegate?) {
    webView.navigationDelegate = delegate
}
```

This follows the project's pattern of keeping `webView` private and providing method-based access (see `toggleMonospace()` line 79, `loadContent()` line 72, `printContent()` line 135).

---

## Shared Patterns

### Access Control
**Source:** All Swift files in `MDViewer/`
**Apply to:** `WebViewPool.swift`
- `final class` for concrete classes not designed for subclassing
- `private` for all implementation details
- `private let` for immutable configuration (capacity)
- `private var` for mutable state (pool array)

### Weak Self in Closures
**Source:** `AppDelegate.swift` lines 30, 85, 162, 186
**Apply to:** `WebViewPool.swift` replenish method
```swift
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    // ...
}
```

### Debug Prints
**Source:** `WebContentView.swift` lines 99-101, `MarkdownWindow.swift` lines 55-57
**Apply to:** `WebViewPool.swift` deinit and discard
```swift
#if DEBUG
print("[WebViewPool] deinit - \(ObjectIdentifier(self))")
#endif
```

### OSSignposter (no changes needed)
**Source:** `AppDelegate.swift` lines 5-8, 145
**Apply to:** No new signpost instrumentation needed. Existing `open-to-paint` interval (line 145) automatically measures the improvement from pool usage.

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `MDViewer/WebViewPool.swift` (crash recovery aspect) | service | event-driven | No existing `WKNavigationDelegate` conformance in the codebase; use Apple API directly (`webViewWebContentProcessDidTerminate`) |

## Test Patterns

**Analog:** `MDViewerTests/MarkdownRendererTests.swift`

Test file conventions:
```swift
import XCTest
@testable import MDViewer

final class WebViewPoolTests: XCTestCase {
    func testSomething() {
        // Arrange
        // Act
        // Assert with XCTAssert*
    }
}
```

Note: `WebViewPool` tests will be limited because `WKWebView` requires a running application host. Tests can verify:
- Pool capacity and dequeue count (pool returns views until empty, then returns nil)
- Replenishment callback fires (use expectations)
- Discard removes view from pool

These require the test target to run as an app host (`MDViewerTests` already links `@testable import MDViewer`).

## Metadata

**Analog search scope:** `MDViewer/`, `MDViewerTests/`
**Files scanned:** 8 (7 source + 1 test)
**Pattern extraction date:** 2026-04-16
