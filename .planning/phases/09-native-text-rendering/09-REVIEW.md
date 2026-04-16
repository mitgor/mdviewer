---
phase: 09-native-text-rendering
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - MDViewer/NativeRenderer.swift
  - MDViewer/NativeContentView.swift
  - MDViewer/MarkdownRenderer.swift
  - MDViewer/MarkdownWindow.swift
  - MDViewer/AppDelegate.swift
  - MDViewerTests/NativeRendererTests.swift
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 09: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found

## Summary

This phase introduces native NSTextView-based rendering as a fast path for markdown documents that do not contain GFM tables or Mermaid diagrams. The design is architecturally sound: the cmark AST is walked once to produce an `NSAttributedString`, font variants are cached at `NativeRenderer` init time, and the rendering path integrates cleanly into the existing two-path (`MarkdownWindow`) window model.

The most significant correctness issue is a **style-stack underflow** in `NativeRenderer.render` that can silently corrupt all subsequent rendering for any document containing an unknown extension node type. Three additional warnings concern: a double AST parse on the happy path (wasted work + latency), a font-registration guard flag that is unsafe across concurrent callers, and a monospace toggle that is wired up as a no-op with no indication to the user. The info-level items are all minor quality issues.

## Warnings

### WR-01: Style-stack underflow on unknown extension EXIT events corrupts all subsequent text

**File:** `MDViewer/NativeRenderer.swift:430-436`

**Issue:** When the iterator fires `CMARK_EVENT_EXIT` for a node whose type string is `nil` (i.e., a non-extension node not handled by any `case` in the EXIT `switch`), the `default` branch falls through to the extension check `if typeString != nil`. Because `typeString` is `nil`, the `removeLast()` is skipped — correct behaviour. However, any ENTER-side branch that pushes a style onto `styleStack` without a matching EXIT-side pop causes permanent stack growth. More critically, the inverse is also true: extension nodes whose ENTER branch is the outer `default` and whose EXIT falls into the inner `default` will try to pop, but non-extension core nodes that hit the EXIT `default` with `typeString == nil` will silently do nothing, leaving the stack unbalanced if the ENTER side did push (e.g., `CMARK_NODE_TEXT`, `CMARK_NODE_CODE`, `CMARK_NODE_SOFTBREAK`, `CMARK_NODE_LINEBREAK`, `CMARK_NODE_HTML_INLINE` — all leaf nodes that push nothing). The real risk is the opposite direction: unknown future cmark node types that the ENTER `default` pushes for (via the extension `default` arm) and that on EXIT produce a `typeString == nil` — the `if styleStack.count > 1 { styleStack.removeLast() }` guard prevents an outright crash but means any such node leaks a frame onto the stack for the document's lifetime.

The more immediately reproducible path: if `cmark_node_get_type_string` returns a non-nil C string for a core node type that is not matched by any explicit ENTER `case`, it will push a style frame. On EXIT, since the EXIT switch also does not match it, the outer `default` fires and the guard `if typeString != nil` pops. This is correct for extension nodes, but the fact that the two branches are not structurally symmetric makes them easy to break independently.

**Fix:** Restructure the ENTER and EXIT `default` branches to use a single `didPush` flag or to make every ENTER arm that pushes unconditionally matched by a canonical EXIT arm. The clearest approach is to introduce an explicit sentinel:

```swift
// ENTER default:
default:
    // Unknown node — push a no-op style copy so EXIT can always pop.
    styleStack.append(currentStyle)

// EXIT default:
default:
    if styleStack.count > 1 {
        styleStack.removeLast()
    }
```

This makes the invariant "every ENTER pushes; every EXIT pops" unconditional and removes the fragile `typeString != nil` conditional.

---

### WR-02: Double AST parse on the native-render happy path wastes ~30% of render time

**File:** `MDViewer/AppDelegate.swift:229-251`

**Issue:** When `forceNative` is `nil` (normal auto-detect), `openFileForced` calls `renderer.parseMarkdown(markdown)` once to run `canRenderNatively`, frees the root, then immediately calls `renderer.parseMarkdown(markdown)` again to produce the root passed to `NativeRenderer.render`. For the common case where native rendering is selected, the markdown is parsed twice. For a 50 KB file this is roughly 20–40 ms of redundant work, which is measurable against the 200 ms first-paint budget.

```swift
// Line 229-237: first parse (canRenderNatively)
guard let root = renderer.parseMarkdown(markdown) else { ... }
useNative = renderer.canRenderNatively(root: root)
cmark_node_free(root)

// Line 242-251: second parse (render)
guard let root = renderer.parseMarkdown(markdown) else { ... }
let nativeResult = nativeRenderer.render(root: root)
cmark_node_free(root)
```

**Fix:** Retain the first root when `canRenderNatively` returns `true` and pass it directly to the renderer:

```swift
guard let root = renderer.parseMarkdown(markdown) else { ... }
useNative = renderer.canRenderNatively(root: root)
if useNative {
    defer { cmark_node_free(root) }
    let nativeResult = nativeRenderer.render(root: root)
    // ... dispatch to main thread
} else {
    cmark_node_free(root)
    // ... web path
}
```

---

### WR-03: `fontsRegistered` static flag is not thread-safe

**File:** `MDViewer/NativeRenderer.swift:63-86`

**Issue:** `NativeRenderer.registerFonts()` is called from `AppDelegate.applicationDidFinishLaunching` (main thread) and also from every `NativeRenderer.init()`. `NativeRenderer()` is created on `DispatchQueue.global(qos: .userInitiated)` (background thread, `AppDelegate.swift:249`). Swift does not guarantee that a plain `private static var Bool` is read-modify-write atomic. If two files are opened simultaneously, two background threads can race on the `fontsRegistered` check-and-set. The consequence is at most double-registration of fonts (which `CTFontManagerRegisterFontsForURL` handles gracefully), but this is still a data race that Swift's concurrency sanitizer will flag.

**Fix:** Use a `DispatchOnce` equivalent. The idiomatic Swift solution is a static `let` with a lazy initializer, which is guaranteed thread-safe by the Swift runtime:

```swift
private static let _fontsOnce: Void = {
    let fontNames = ["lmroman10-regular.otf", "lmroman10-bold.otf", "lmmono10-regular.otf"]
    for name in fontNames {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}()

static func registerFonts() {
    _ = _fontsOnce
}
```

---

### WR-04: `toggleMonospace` in `NativeContentView` is a silent no-op with no user feedback

**File:** `MDViewer/NativeContentView.swift:94-97`

**Issue:** `toggleMonospace()` flips `isMonospace` but does not re-render or update the displayed text. The method comment says "Will be wired to NativeRenderer re-render in Plan 02," meaning a user invoking View > Toggle Monospace on a native-rendered window will see the menu item respond (no error) but the document will not change. There is no alert, no visual feedback, and no disabled menu item to indicate the feature is unimplemented. This is a user-visible bug in the current state.

**Fix (short-term):** Disable the menu item when the key window is using native rendering, or show a brief alert:

```swift
// In AppDelegate.toggleMonospace(_:):
} else if let nativeView = window.nativeContentView {
    // Placeholder: show informational alert until re-render is wired up
    let alert = NSAlert()
    alert.messageText = "Monospace Toggle Unavailable"
    alert.informativeText = "Monospace toggle is not yet supported in native rendering mode."
    alert.alertStyle = .informational
    alert.runModal()
}
```

**Fix (long-term):** Implement re-render through `NativeRenderer` with `isMonospace` passed as a parameter, replacing the body font with `codeFont` throughout.

---

### WR-05: `NativeContentView.printContent` force-casts `NSPrintInfo.shared.copy()` with `as!`

**File:** `MDViewer/NativeContentView.swift:103`

**Issue:** `NSPrintInfo.shared.copy() as! NSPrintInfo` uses a force-cast. While `NSPrintInfo.copy()` is documented to return `Any` and will always be an `NSPrintInfo` in practice, the `as!` is a crash risk if AppKit's behaviour changes and violates project convention (the codebase uses `guard let` for failable operations). If the cast fails in an unexpected environment or during testing, it crashes the app silently during a print operation.

**Fix:**

```swift
func printContent(title: String) {
    guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
    let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
    printOp.showsPrintPanel = true
    printOp.showsProgressPanel = true
    printOp.run()
}
```

---

## Info

### IN-01: `NativeRenderer.resolveFont` iterates `headingFonts` dictionary for point-size lookup — O(n) when O(1) is available

**File:** `MDViewer/NativeRenderer.swift:522-527`

**Issue:** When resolving a bold font at a non-body size (i.e., heading), `resolveFont` iterates all entries in `headingFonts` comparing `pointSize` to find the cached font. Since `headingFonts` is keyed by heading level (1–6) and heading sizes are derived from level, the direct lookup `headingFonts[level]` would be O(1). The level is available in `StyleState.fontSize` only indirectly (must reverse-compute), but the current approach is unnecessarily indirect. This is not a bug but reduces the elegance of the caching that was set up at init time.

**Suggestion:** Store the heading level in `StyleState` (as an `Int?`, `nil` for body text) so `resolveFont` can do a direct dictionary lookup rather than a float-comparison scan.

---

### IN-02: Module-level `nativeRenderingSignposter` constant is exposed globally

**File:** `MDViewer/NativeRenderer.swift:11-14`

**Issue:** `nativeRenderingSignposter` is declared at module level (not `private` inside `NativeRenderer`), inconsistent with the project's convention of scoping constants to their owning type. Compare `renderingSignposter` in `MarkdownRenderer.swift:28` (same pattern — also module-level), but both should be `private` statics on their respective types.

**Suggestion:** Move into the type as a private static:

```swift
final class NativeRenderer {
    private static let signposter = OSSignposter(
        subsystem: "com.mdviewer.app",
        category: "NativeRendering"
    )
    // ...
}
```

---

### IN-03: `canRenderNatively` only scans top-level nodes — nested tables inside blockquotes are not detected

**File:** `MDViewer/MarkdownRenderer.swift:272-288`

**Issue:** The method walks `cmark_node_first_child(root)` → `cmark_node_next(node)` (top-level children only). A GFM table nested inside a blockquote (valid CommonMark) would not be detected, causing the native path to be selected for a document it cannot render correctly (tables are silently dropped by `NativeRenderer`). The practical risk is low (rare document structure), but the check does not match its documented semantics.

**Suggestion:** Perform a full depth-first traversal, or document explicitly that only top-level node detection is supported and tables inside blockquotes will render as empty space.

---

### IN-04: `NativeContentView.cachedAttributedString` is stored but never read after assignment

**File:** `MDViewer/NativeContentView.swift:19, 81`

**Issue:** `cachedAttributedString` is set in `loadContent` but the only code that reads it is... nothing (the `toggleMonospace` stub does not use it). Until monospace re-rendering is implemented (WR-04), this field is dead storage. Not a bug, but it's a signal that the feature is incomplete.

**Suggestion:** Add a `// TODO(Plan-02): used by toggleMonospace re-render` comment or defer declaring the property until the consuming code exists.

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
