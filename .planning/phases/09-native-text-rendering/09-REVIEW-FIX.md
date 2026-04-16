---
phase: 09-native-text-rendering
fixed_at: 2026-04-16T00:00:00Z
review_path: .planning/phases/09-native-text-rendering/09-REVIEW.md
iteration: 1
findings_in_scope: 5
fixed: 5
skipped: 0
status: all_fixed
---

# Phase 09: Code Review Fix Report

**Fixed at:** 2026-04-16
**Source review:** .planning/phases/09-native-text-rendering/09-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 5
- Fixed: 5
- Skipped: 0

## Fixed Issues

### WR-01: Style-stack underflow on unknown extension EXIT events corrupts all subsequent text

**Files modified:** `MDViewer/NativeRenderer.swift`
**Commit:** 66d5bf0
**Applied fix:** Made ENTER default branch unconditionally push a style frame for both extension and unknown core nodes (added `else` clause for `typeString == nil`). Made EXIT default branch unconditionally pop regardless of `typeString`, removing the fragile conditional guard. This ensures every ENTER pushes and every EXIT pops, maintaining stack balance for all node types.

### WR-02: Double AST parse on the native-render happy path wastes ~30% of render time

**Files modified:** `MDViewer/AppDelegate.swift`
**Commit:** 27f777b
**Applied fix:** Retained the AST root from the `canRenderNatively` auto-detect parse when native rendering is selected. The root is passed directly to `NativeRenderer.render` instead of being freed and re-parsed. When `forceNative` is set (no auto-detect), a fresh parse still occurs as before. This eliminates ~20-40ms of redundant work on the common path.

### WR-03: `fontsRegistered` static flag is not thread-safe

**Files modified:** `MDViewer/NativeRenderer.swift`
**Commit:** 6fccb20
**Applied fix:** Replaced `private static var fontsRegistered = false` check-and-set pattern with `private static let _fontsOnce: Void = { ... }()` lazy initializer. Swift guarantees static let initialization is thread-safe (dispatch_once semantics). The public `registerFonts()` method now simply evaluates `_ = _fontsOnce`.

### WR-04: `toggleMonospace` in `NativeContentView` is a silent no-op with no user feedback

**Files modified:** `MDViewer/NativeContentView.swift`
**Commit:** 7951da1
**Applied fix:** Replaced the silent `isMonospace.toggle()` with an informational `NSAlert` that tells the user monospace toggle is not yet supported in native rendering mode. This provides clear feedback instead of silently doing nothing. The `isMonospace` toggle was removed since it had no effect.

### WR-05: `NativeContentView.printContent` force-casts `NSPrintInfo.shared.copy()` with `as!`

**Files modified:** `MDViewer/NativeContentView.swift`
**Commit:** 709344f
**Applied fix:** Replaced `NSPrintInfo.shared.copy() as! NSPrintInfo` with `guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }`, consistent with project convention of using `guard let` for failable operations.

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
