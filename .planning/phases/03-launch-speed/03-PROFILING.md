# Launch Profiling Results

**Device:** Apple M4 Max, 64GB RAM
**macOS:** 26.3.1 (Tahoe)
**Build:** Release, Xcode 26
**Test file:** Small markdown file (~1-5KB)
**Measured:** 2026-04-06 via Instruments os_signpost (RenderingPipeline category)

> Measured values from Instruments os_signpost profiling on Apple Silicon hardware.

## Timing Data

| Metric | Warm Launch (Measured) | Target | Status |
|--------|----------------------|--------|--------|
| launch-to-paint | 184.50ms | <100ms | FAILED |
| open-to-paint | 139.00ms | -- | Baseline |
| Cold launch-to-paint | Not measured | -- | -- |

### Stage Analysis

- **launch-to-paint (184.50ms)** is 84% over the 100ms warm launch target.
- **open-to-paint (139.00ms)** accounts for most of the launch-to-paint interval. The gap between launch-to-paint and open-to-paint (~45ms) represents app startup overhead before the first file open.
- **WKWebView init** could not be isolated as a separate interval in the Instruments trace. The pre-warm moves init to applicationDidFinishLaunching, so its cost is absorbed into the pre-open-to-paint startup window.
- Cold launch was not measured in this session.

## Decision: WKWebView Pre-Warm

- **WKWebView init cost (measured):** Not separately isolable in trace — absorbed into ~45ms pre-open startup window
- **Threshold:** 20ms (per D-01)
- **Decision:** **Implemented** (pre-warm is active in these measurements)
- **Evidence:** Instruments os_signpost trace on M4 Max, macOS 26.3.1. Pre-warm is already active in these measurements — the 184.50ms warm launch includes pre-warmed WKWebView reuse.
- **Implementation:** Single pre-warmed `WebContentView` created in `applicationDidFinishLaunching`, reused for the first file open.

### Pre-Warm Impact

The pre-warm optimization is already active in the measured 184.50ms. Without pre-warm, the warm launch-to-paint would likely be ~215-225ms (adding estimated ~30-40ms WKWebView init back to the critical path). The pre-warm helps but is insufficient to reach the 100ms target.

### Cold vs Warm Classification (per D-05)

- **Warm launch (measured):** 184.50ms — frameworks in disk cache, second consecutive run
- **Cold launch:** Not measured in this session

## LAUNCH-03 NOT MET

**Warm launch-to-paint: 184.50ms (target: <100ms)**

The sub-100ms warm launch target is not achieved. The measured warm launch is nearly 2x the target. The pre-warm optimization is active and moves WKWebView init off the critical path, but the remaining pipeline (template loading, HTML string construction, WKWebView loadHTMLString, initial layout + paint) still takes ~139ms from file open to first paint.

### Further Optimization Needed

To reach sub-100ms warm launch, investigation is needed in these areas:

1. **WKWebView loadHTMLString overhead (~139ms open-to-paint):** The dominant cost is WKWebView rendering the HTML page. Possible approaches:
   - Pre-load the template HTML into the pre-warmed WKWebView (so it's ready to receive content injection)
   - Use `loadFileURL` instead of `loadHTMLString` (may avoid HTML parsing overhead)
   - Reduce initial HTML payload size (smaller first chunk)

2. **App startup overhead (~45ms before file open):** The gap between launch-to-paint and open-to-paint suggests ~45ms of startup before the file is opened. Possible approaches:
   - Defer non-essential startup work
   - Profile applicationDidFinishLaunching for bottlenecks

3. **Signpost sub-intervals:** Add more granular signpost intervals to isolate exactly which stage within open-to-paint is slowest (file read, parse, template concat, loadHTMLString, JS execution, first paint callback).

**Measurement date:** 2026-04-06
**Instruments template:** os_signpost
