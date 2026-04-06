# Phase 3: Launch Speed - Research

**Researched:** 2026-04-06
**Domain:** macOS app launch optimization, WKWebView pre-warming, OSSignposter launch measurement
**Confidence:** HIGH

## Summary

Phase 3 is a profiling-driven optimization phase. The existing OSSignposter instrumentation (from Phase 1) already measures five pipeline stages: file-read, parse, chunk-split, chunk-inject, and open-to-paint. The missing piece is a **launch-to-paint** interval that starts at the earliest possible point in `main.swift` and ends at the first paint callback, measuring the full app-launch-to-content pipeline including app startup overhead, template loading, and WKWebView creation.

The critical question is whether WKWebView creation is a significant bottleneck. Industry data suggests WKWebView initialization costs 50-100+ms on iOS; on Apple Silicon macOS the cost is likely lower but still meaningful relative to a 100ms budget. The CONTEXT.md decisions mandate a profile-first approach: measure WKWebView creation cost, then implement pre-warming only if it exceeds 20ms. The pre-warm pattern is straightforward -- create a hidden WKWebView with the correct configuration during `applicationDidFinishLaunching`, pre-load the template HTML, and hand it off for the first file open.

The current launch path has several sequential steps on the critical path: (1) `main.swift` creates NSApplication and AppDelegate, (2) `applicationDidFinishLaunching` loads the template synchronously, (3) `openFile` dispatches rendering to background thread, (4) `displayResult` creates WKWebView and loads HTML, (5) first paint callback fires. Steps 1-2 happen before any file processing. Steps 3-4 overlap partially (rendering is background, but WKWebView creation is main thread). The optimization targets are template loading, WKWebView creation, and any unnecessary serialization between steps.

**Primary recommendation:** Add a launch-to-paint signpost in `main.swift`, profile the warm launch path with Instruments, then optimize only stages that consume >10% of the budget (>10ms). WKWebView pre-warming is the highest-probability win based on industry data showing 50+ms initialization cost.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Profile the current launch path first. Only implement WKWebView pre-warming if signpost data shows WKWebView creation is a significant bottleneck (>20ms of the launch path). If not a bottleneck, document the profiling evidence and skip.
- **D-02:** If pre-warming is implemented: create a hidden WKWebView during `applicationDidFinishLaunching`, pre-load the template HTML, and reuse it for the first file open. Subsequent windows create their own WKWebView as they do today.
- **D-03:** The pre-warm decision must be documented either way -- success criteria #2 requires this resolution.
- **D-04:** Add a new signpost interval from `main()` (or earliest possible point) to first paint callback, measuring the full app-launch-to-content pipeline.
- **D-05:** Measure cold launch (first launch since boot) and warm launch (subsequent launch) separately. Record both in a profiling results document or code comment.
- **D-06:** The 100ms target applies to warm launch only (per success criteria #1).
- **D-07:** Profile-then-optimize approach. Use the existing OSSignposter intervals to identify the actual bottlenecks before making any changes.
- **D-08:** Only optimize stages that consume >10% of the launch path. Do not speculatively optimize things that profiling shows are fast.

### Claude's Discretion
- Whether template loading needs optimization (profile first -- currently synchronous file read)
- Whether `cmark_gfm_core_extensions_ensure_registered()` should be moved earlier in the launch path
- The specific threshold for deciding WKWebView pre-warm is "worth it" (recommendation: 20ms, but adjust based on profiling data)
- Whether to add a launch-time signpost at the `main()` level or at `applicationDidFinishLaunching`

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| LAUNCH-02 | WKWebView pre-warmed at app launch -- reused for first file open | Pre-warm pattern (see Architecture Patterns), profile-first decision gate per D-01/D-02/D-03 |
| LAUNCH-03 | Sub-100ms warm launch to first visible content on Apple Silicon | Launch-to-paint signpost (see Architecture Patterns), optimization strategy based on profiling data |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: macOS 13+ (Ventura minimum). All APIs used must be available at this target.
- **No network**: All resources bundled. No external dependencies to add.
- **Read-only**: No file modification, no state persistence.
- **Speed**: First content visible in <200ms (current requirement); this phase tightens to <100ms for warm launch.
- **Concurrency convention**: Always capture `[weak self]` in closures. Main thread dispatch for all UI mutations.
- **Memory convention**: `weak` for delegate references. `isReleasedWhenClosed = false` on NSWindow.
- **Access control**: `private` for implementation details. `final` on concrete classes.
- **No async/await migration**: Explicitly out of scope per REQUIREMENTS.md.

## Standard Stack

### Core

| Library/API | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| `OSSignposter` | macOS 12+ (os framework) | Launch-to-paint and per-stage interval measurement | Already in use (Phase 1). Zero overhead when Instruments not attached. Native Instruments integration. |
| `WKWebView` | macOS 10.10+ (WebKit) | Pre-warm target -- the most expensive object in the launch path | Already the rendering surface. Pre-warming reuses the existing creation pattern. |
| `WKWebViewConfiguration` | macOS 10.10+ (WebKit) | Configuration must match between pre-warmed and production WKWebView | Configuration is set once at creation; pre-warmed view must use identical config to avoid recreation. |

### Supporting

| Library/API | Version | Purpose | When to Use |
|-------------|---------|---------|-------------|
| `OSSignpostID` | macOS 12+ | Disambiguate launch-to-paint from open-to-paint intervals | When both intervals are active simultaneously during first file open. |
| `ProcessInfo.processInfo.systemUptime` | macOS 10.0+ | Cheap timestamp for cold vs warm heuristic | Optional: compare process start time to system uptime to classify launch type. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| OSSignposter launch interval | `CFAbsoluteTimeGetCurrent()` in main.swift | No Instruments integration, adds measurement overhead. OSSignposter is zero-cost when not profiling. Use OSSignposter. |
| WKWebView pre-warm singleton | WKWebView pool of N instances | Overkill for this app. MDViewer opens one file at a time typically. Single pre-warmed instance is sufficient per D-02. |
| Template pre-load into WKWebView | Template pre-split only (current) | Current `SplitTemplate` is already O(1) concatenation. Pre-loading template HTML into a WKWebView goes further by eliminating the `loadHTMLString` latency for the first file. |

**No installation needed** -- all APIs are in system frameworks already linked by the project.

## Architecture Patterns

### Current Launch Path (Critical Path Analysis)

```
main.swift
  |-- NSApplication.shared              ~0ms (getter)
  |-- AppDelegate()                     ~Xms (MarkdownRenderer() calls cmark_gfm_core_extensions_ensure_registered)
  |-- app.run()
        |-- applicationDidFinishLaunching
        |     |-- loadTemplate()        ~Xms (synchronous file read + string split)
        |     |-- setupMenu()           ~Xms (NSMenu construction)
        |     |-- DispatchQueue.main.async { openFile(args[1]) }
        |
        |-- openFile(url)                         [START: open-to-paint signpost]
        |     |-- DispatchQueue.global {
        |     |     |-- renderFullPage()          [file-read + parse + chunk-split signposts]
        |     |     |-- DispatchQueue.main.async {
        |     |           |-- displayResult()
        |     |                 |-- WebContentView(frame:)  ~Xms (WKWebView creation!)
        |     |                 |-- loadContent()           ~Xms (loadHTMLString)
        |     |                 |-- makeKeyAndOrderFront
        |     |}
        |
        |-- firstPaint callback                   [END: open-to-paint signpost]
```

### Pattern 1: Launch-to-Paint Signpost in main.swift

**What:** A signpost interval starting at the very first line of `main.swift`, ending when the first paint callback fires. This measures everything: AppDelegate init, template loading, rendering, WKWebView creation, and HTML loading.

**When to use:** Always -- this is the measurement that maps to the 100ms success criterion.

**Example:**
```swift
// main.swift
import Cocoa
import os

// Earliest possible measurement point
let launchSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
let launchSignpostState = launchSignposter.beginInterval("launch-to-paint")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

The `launchSignpostState` must be accessible to `AppDelegate` so it can be ended in `webContentViewDidFinishFirstPaint`. Options:
- Global `let` (simplest, matches existing `renderingSignposter` pattern)
- Pass through AppDelegate init parameter

**Recommendation:** Use module-level globals. The existing codebase already uses `renderingSignposter` and `appSignposter` as module-level constants. Add `launchSignposter` and `launchSignpostState` at the top of `main.swift`, reference them from `AppDelegate`.

```swift
// In AppDelegate.webContentViewDidFinishFirstPaint:
func webContentViewDidFinishFirstPaint(_ view: WebContentView) {
    // End launch-to-paint on first ever paint
    if !hasCompletedFirstLaunchPaint {
        hasCompletedFirstLaunchPaint = true
        launchSignposter.endInterval("launch-to-paint", launchSignpostState)
    }
    // ... existing open-to-paint logic ...
}
```

### Pattern 2: WKWebView Pre-Warm (Conditional on Profiling)

**What:** Create a WKWebView during `applicationDidFinishLaunching` with the same configuration used in production. Optionally pre-load the template HTML shell (without content). When the first file open occurs, reuse this pre-warmed view instead of creating a new one.

**When to use:** Only if profiling shows WKWebView creation costs >20ms (per D-01).

**Example:**
```swift
// In AppDelegate:
private var preWarmedContentView: WebContentView?

func applicationDidFinishLaunching(_ notification: Notification) {
    loadTemplate()
    setupMenu()

    // Pre-warm WKWebView for first file open
    preWarmedContentView = WebContentView(frame: .zero)

    // ... existing code ...
}

private func displayResult(_ result: RenderResult, for url: URL, paintState: OSSignpostIntervalState) {
    // Use pre-warmed view for first file, create fresh for subsequent
    let contentView: WebContentView
    if let preWarmed = preWarmedContentView {
        contentView = preWarmed
        preWarmedContentView = nil
    } else {
        contentView = WebContentView(frame: .zero)
    }

    contentView.delegate = self
    openToPaintStates[ObjectIdentifier(contentView)] = paintState

    let window = MarkdownWindow(fileURL: url, contentView: contentView)
    // ... rest unchanged ...
}
```

**Key constraint:** The pre-warmed WKWebView must use the exact same `WKWebViewConfiguration` as a fresh one. Since `WebContentView.init(frame:)` creates the configuration internally, the pre-warm simply calls the same init -- no configuration mismatch risk.

### Pattern 3: Template Pre-Load into Pre-Warmed WKWebView

**What:** After pre-warming the WKWebView, load the template HTML shell (with an empty `{{FIRST_CHUNK}}`) so the web process is fully initialized and the DOM is ready. When content arrives, inject it via JavaScript rather than calling `loadHTMLString`.

**When to use:** Only if both (a) WKWebView pre-warm is implemented and (b) profiling shows `loadHTMLString` is a significant additional cost.

**Complexity:** Higher -- requires a new code path where the first file open injects content into an already-loaded template rather than loading a full HTML page. This changes the `loadContent` API surface.

**Recommendation:** Start with Pattern 2 (pre-warm only) and measure. Only add template pre-load if the simpler pre-warm is insufficient to hit 100ms.

### Pattern 4: Cold vs Warm Launch Classification

**What:** Record whether each launch is cold or warm, and log the distinction alongside timing data.

**When to use:** Always -- success criteria require separate measurement.

**Example:**
```swift
// In main.swift or AppDelegate
// Heuristic: if process uptime is very close to system uptime, it's likely a cold boot
// More practical: just record the launch-to-paint time and let the developer classify
// based on whether they just rebooted.

// Simple approach: log the launch time and let Instruments traces be labeled manually
// as "cold" or "warm" based on test conditions.
```

**Recommendation:** Don't automate cold/warm detection. Instead, document a test protocol:
1. **Cold launch:** Reboot, launch app with a test file, record Instruments trace.
2. **Warm launch:** Launch app once, quit, launch again with same file, record trace.
3. Record both times in a results table.

### Anti-Patterns to Avoid

- **Pre-warming without profiling data:** D-01 explicitly forbids this. Profile first, optimize second.
- **Sharing WKWebViewConfiguration between pre-warmed and fresh views incorrectly:** If the pre-warmed view uses a different configuration (e.g., missing `developerExtrasEnabled` in DEBUG), it will behave differently. Use the same init path.
- **Pre-warming multiple WKWebViews:** MDViewer is a document viewer, not a browser. One pre-warmed view is sufficient. Don't pool.
- **Moving cmark init to main.swift:** `cmark_gfm_core_extensions_ensure_registered()` is called in `MarkdownRenderer.init()`, which happens when AppDelegate is created (before `applicationDidFinishLaunching`). Moving it earlier gains nothing -- it's already on the critical path and likely takes <1ms.
- **Async template loading:** Template is a small bundled file. Making it async adds complexity for negligible gain. Profile first.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Launch timing | Manual `Date()` timestamps | `OSSignposter` interval from main.swift | Zero-cost when not profiling, native Instruments integration, structured intervals |
| WKWebView warm-up | Custom WebKit process pool management | Simple pre-create of `WebContentView` during didFinishLaunching | `WKProcessPool` customization has no effect since macOS 12. Just create the view early. |
| Cold/warm classification | Automated detection heuristic | Manual test protocol with Instruments | Automated detection is unreliable. A documented test procedure is more trustworthy. |
| Launch time regression tests | CI-based timing assertions | `XCTOSSignpostMetric.applicationLaunch` in XCTest | Apple's built-in performance test metric handles variance and provides statistical analysis. |

## Common Pitfalls

### Pitfall 1: Pre-Warming a WKWebView That Gets Discarded

**What goes wrong:** The pre-warmed WKWebView is created with a configuration that doesn't match what `displayResult` expects, so it gets discarded and a fresh one is created anyway.
**Why it happens:** Configuration mismatch between pre-warm and production path.
**How to avoid:** Pre-warm by calling the exact same `WebContentView(frame: .zero)` init that `displayResult` uses. The configuration is internal to `WebContentView`, so using the same init guarantees compatibility.
**Warning signs:** Two WKWebView processes visible in Activity Monitor during first file open.

### Pitfall 2: Launch Signpost Never Ends

**What goes wrong:** The `launch-to-paint` signpost interval stays open forever because no file was opened (user launched app via Cmd+O, not by double-clicking a file).
**Why it happens:** The signpost starts unconditionally in `main.swift` but only ends when `webContentViewDidFinishFirstPaint` fires.
**How to avoid:** Add a timeout or guard: if no file is opened within N seconds of launch, end the signpost with a "no-file" annotation. Alternatively, only start the launch signpost when `openFile` is called from the argument path (not from `Cmd+O`).
**Warning signs:** Instruments shows an infinitely long interval.

### Pitfall 3: Measuring Release Build Performance with Debug Build

**What goes wrong:** Debug builds include extra logging, assertions, and unoptimized code. Performance numbers from Debug builds are meaningless for the 100ms target.
**Why it happens:** Xcode defaults to Debug scheme for running.
**How to avoid:** Always profile with Release build in Instruments. The Phase 1 research already noted this (Pitfall 5).
**Warning signs:** Times are 2-3x slower than expected.

### Pitfall 4: Pre-Warmed View Leaks if App Quits Without Opening a File

**What goes wrong:** If the user launches MDViewer but closes it (or it terminates) without opening any file, the pre-warmed `WebContentView` is never used and must be properly deallocated.
**Why it happens:** `preWarmedContentView` is a strong reference in AppDelegate. If AppDelegate is deallocated normally, the view is released. But if something else holds a reference (unlikely given current architecture), it could leak.
**How to avoid:** Set `preWarmedContentView = nil` in `applicationWillTerminate` or simply rely on AppDelegate deallocation (which happens at app exit). This is a minor concern for a macOS app that terminates its process on quit.
**Warning signs:** None in practice -- process termination cleans up all memory.

### Pitfall 5: DispatchQueue.main.async Delay in applicationDidFinishLaunching

**What goes wrong:** The current code uses `DispatchQueue.main.async` to defer `openFile` until after delegate setup. This adds one run loop iteration of latency (potentially 16ms at 60Hz or 8ms at 120Hz).
**Why it happens:** The async dispatch was added to ensure `application(_:open:)` has a chance to fire first (via `openedViaDelegate` flag). Without it, command-line arguments could race with delegate file opens.
**How to avoid:** This is a necessary design decision. The async dispatch is required for correctness. Don't try to remove it. The 8-16ms cost is part of the budget.
**Warning signs:** None -- this is expected behavior.

## Code Examples

### Complete main.swift with Launch Signpost

```swift
// Source: Existing main.swift pattern + OSSignposter from Phase 1
import Cocoa
import os

let launchSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
let launchSignpostState = launchSignposter.beginInterval("launch-to-paint")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

### WKWebView Pre-Warm in AppDelegate (Conditional Implementation)

```swift
// Source: WebViewWarmUper pattern adapted for MDViewer architecture
// Only implement if profiling shows WKWebView init > 20ms

private var preWarmedContentView: WebContentView?
private var hasCompletedFirstLaunchPaint = false

func applicationDidFinishLaunching(_ notification: Notification) {
    loadTemplate()
    setupMenu()

    // Pre-warm: create WKWebView now so it's ready for first file open
    preWarmedContentView = WebContentView(frame: .zero)

    NSApp.activate(ignoringOtherApps: true)
    // ... existing deferred openFile logic ...
}

private func displayResult(_ result: RenderResult, for url: URL, paintState: OSSignpostIntervalState) {
    let contentView: WebContentView
    if let preWarmed = preWarmedContentView {
        contentView = preWarmed
        preWarmedContentView = nil  // Only first file gets pre-warmed view
    } else {
        contentView = WebContentView(frame: .zero)
    }
    contentView.delegate = self
    openToPaintStates[ObjectIdentifier(contentView)] = paintState
    // ... rest unchanged ...
}
```

### Launch Signpost Completion in AppDelegate

```swift
// Source: Existing webContentViewDidFinishFirstPaint pattern extended
func webContentViewDidFinishFirstPaint(_ view: WebContentView) {
    // End launch-to-paint on the very first paint event
    if !hasCompletedFirstLaunchPaint {
        hasCompletedFirstLaunchPaint = true
        launchSignposter.endInterval("launch-to-paint", launchSignpostState)
    }

    // Existing open-to-paint logic
    if let paintState = openToPaintStates.removeValue(forKey: ObjectIdentifier(view)) {
        appSignposter.endInterval("open-to-paint", paintState)
    }
    if let window = windows.first(where: { $0.contentViewWrapper === view }) {
        window.showWithFadeIn()
    }
}
```

### Profiling Results Template

```markdown
## Launch Profiling Results

**Device:** Apple M4 Max, macOS 26.3
**Build:** Release, Xcode 26.4
**Test file:** [filename, size]

| Metric | Cold Launch | Warm Launch | Target |
|--------|------------|-------------|--------|
| launch-to-paint | Xms | Xms | <100ms (warm) |
| open-to-paint | Xms | Xms | -- |
| file-read | Xms | Xms | -- |
| parse | Xms | Xms | -- |
| chunk-split | Xms | Xms | -- |
| WKWebView init | Xms | Xms | <20ms threshold |

### Decision: WKWebView Pre-Warm
- **WKWebView init cost:** Xms
- **Decision:** [Implemented / Rejected]
- **Evidence:** [Instruments trace reference]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `DYLD_PRINT_STATISTICS` for dylib analysis | Instruments App Launch template | macOS 12+ | Integrated view of pre-main and post-main time |
| Multiple `WKProcessPool` instances for isolation | Single default pool (Apple changed behavior) | macOS 12 / iOS 15 | Custom pool creation no longer has any effect |
| `os_signpost()` C function | `OSSignposter` class | macOS 12 / WWDC 2021 | Swift-native, same Instruments integration |
| `XCTMetric` manual timing | `XCTOSSignpostMetric.applicationLaunch` | Xcode 13+ | Automated launch time regression testing |

**Deprecated/outdated:**
- Custom `WKProcessPool` allocation: Has no effect since macOS 12. Don't bother.
- `DYLD_PRINT_STATISTICS`: Still works but Instruments App Launch template provides richer data.

## Open Questions

1. **Actual WKWebView init cost on Apple Silicon macOS**
   - What we know: iOS data shows 50-100+ms. macOS on Apple Silicon is likely faster due to more memory bandwidth and no thermal throttling.
   - What's unclear: Exact cost on M4 Max running macOS 26. Could be 10ms or 60ms.
   - Recommendation: This is the key unknown that profiling in Wave 1 will resolve. The entire optimization strategy depends on this number.

2. **Template loading cost**
   - What we know: `loadTemplate()` reads a bundled HTML file and splits it at a marker. The file is small (likely <100KB).
   - What's unclear: Whether this is <1ms or >5ms on warm launch.
   - Recommendation: Profiling will show. Likely negligible but worth measuring since it's on the critical path before `openFile`.

3. **DispatchQueue.main.async latency for argument-based file open**
   - What we know: The deferred `openFile` call adds one run loop iteration. At ProMotion 120Hz this is ~8ms.
   - What's unclear: Whether this latency is avoidable without breaking the `openedViaDelegate` guard.
   - Recommendation: Accept this cost. The guard is necessary for correctness (preventing duplicate opens). 8ms is within budget if other stages are fast.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode | Building and profiling | Yes | 26.4 | -- |
| Instruments | Profiling signpost intervals | Yes | (bundled with Xcode) | -- |
| Apple Silicon | 100ms target calibrated for | Yes | M4 Max | -- |

No missing dependencies.

## Sources

### Primary (HIGH confidence)
- Phase 1 Research (`01-RESEARCH.md`) -- OSSignposter API patterns, subsystem/category conventions
- Phase 1 Summary (`01-01-SUMMARY.md`) -- Existing signpost instrumentation details
- Current source code (`main.swift`, `AppDelegate.swift`, `WebContentView.swift`, `MarkdownRenderer.swift`) -- Actual launch path implementation
- [WKWebView | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkwebview) -- API surface
- [WKWebViewConfiguration | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration) -- Configuration requirements
- [WKProcessPool | Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkprocesspool) -- Pool behavior changes since macOS 12

### Secondary (MEDIUM confidence)
- [WebViewWarmUper (GitHub)](https://github.com/bernikovich/WebViewWarmUper) -- Pre-warm pattern showing 40-45% load time reduction
- [App Launch Time: 7 tips (SwiftLee)](https://www.avanderlee.com/optimization/launch-time-performance-optimization/) -- Cold/warm/resume definitions, optimization strategies
- [Why Is WKWebView So Heavy (Embrace.io)](https://embrace.io/blog/wkwebview-memory-leaks/) -- WKWebView initialization cost analysis (50-100+ms on iOS)
- [Creating WKWebView blocks main thread (Adobe SDK issue)](https://github.com/adobe/aepsdk-assurance-ios/issues/106) -- Real-world evidence of 50+ms WKWebView init blocking
- [Reducing your app's launch time (Apple)](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) -- Official Apple guidance on launch optimization

### Tertiary (LOW confidence)
- WKWebView init cost on Apple Silicon macOS -- extrapolated from iOS data; actual measurement needed (this is the primary open question)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all APIs already in use from Phase 1, no new dependencies
- Architecture: HIGH -- pre-warm pattern is well-documented and simple; launch signpost is a straightforward extension of existing instrumentation
- Pitfalls: HIGH -- all pitfalls are based on direct code reading and known WebKit behaviors
- Performance targets: MEDIUM -- 100ms budget is achievable on Apple Silicon based on industry data, but actual WKWebView init cost on this specific platform is unverified (must profile)

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable APIs, 30-day validity)
