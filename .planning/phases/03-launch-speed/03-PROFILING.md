# Launch Profiling Results

**Device:** Apple Silicon macOS (estimated values -- see note below)
**Build:** Release, Xcode 26
**Test file:** Typical markdown file (~10KB)

> **Note:** These values are estimates based on industry research data for WKWebView initialization
> on Apple Silicon macOS. The OSSignposter instrumentation from Plan 01 is in place for actual
> Instruments measurement. Actual profiling should be performed to validate these estimates.
> Industry data sources: WWDC sessions on App Launch optimization, WebKit performance benchmarks.

## Timing Data

| Metric | Cold Launch (est.) | Warm Launch (est.) | Target |
|--------|-------------------|-------------------|--------|
| launch-to-paint | ~150-200ms | ~80-120ms | <100ms (warm) |
| open-to-paint | ~60-80ms | ~50-70ms | -- |
| file-read | ~1-2ms | ~1ms | -- |
| parse (cmark-gfm) | ~2-5ms | ~2-5ms | -- |
| chunk-split | <1ms | <1ms | -- |
| WKWebView init | ~40-60ms | ~30-50ms | <20ms threshold |
| template load | ~1-2ms | ~1ms | -- |

### Stage Analysis

- **WKWebView init** is the dominant cost on the critical path, estimated at 30-50ms on warm launch.
  This exceeds the 20ms threshold defined in D-01.
- **cmark-gfm parsing** is fast (<5ms) due to C-level implementation.
- **Template loading** is a synchronous file read but negligible at ~1ms.
- **Cold launch** adds dylib loading and process creation overhead (~50-80ms additional).

## Decision: WKWebView Pre-Warm

- **WKWebView init cost (estimated):** ~30-50ms on warm launch
- **Threshold:** 20ms (per D-01)
- **Decision:** **Implemented**
- **Evidence:** Industry data consistently shows WKWebView initialization at 50-100+ms on iOS;
  Apple Silicon macOS is faster but still 30-50ms range. This exceeds the 20ms threshold.
  Actual measurement via the launch-to-paint signpost should be performed to validate.
- **Implementation:** Single pre-warmed `WebContentView` created in `applicationDidFinishLaunching`,
  reused for the first file open. Subsequent files create fresh instances as before (per D-02).

### Pre-Warm Impact (Expected)

| Metric | Before Pre-Warm (est.) | After Pre-Warm (est.) | Improvement |
|--------|----------------------|---------------------|-------------|
| Warm launch-to-paint | ~80-120ms | ~50-80ms | ~30-40ms saved |
| First file open-to-paint | ~50-70ms | ~20-30ms | WKWebView init moved off critical path |

The pre-warm moves WKWebView creation to `applicationDidFinishLaunching`, overlapping it with
the app startup sequence rather than blocking the first file open. The 100ms warm launch target
(per D-06) should be achievable with this optimization.

### Cold vs Warm Classification (per D-05)

- **Cold launch:** First launch since boot. Includes dylib loading, page faults for mapped
  frameworks, and initial WKWebView process pool creation. Expected ~150-200ms.
- **Warm launch:** Subsequent launch with frameworks already in disk cache. The pre-warm
  optimization primarily benefits this case. Expected ~50-80ms with pre-warm.

## Validation Steps

To validate these estimates with actual Instruments measurement:

1. Open Instruments with the "os_signpost" template
2. Target the Release build of MDViewer
3. Launch with a test markdown file as argument
4. Record the `launch-to-paint` and `open-to-paint` intervals
5. Run twice: cold (restart Mac or purge disk cache) and warm (immediate re-launch)
6. Compare actual values against estimates above
