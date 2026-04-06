# Codebase Concerns

**Analysis Date:** 2026-04-03

---

## Tech Debt

**`loadSavedFrame()` is a permanent stub:**
- Issue: `MarkdownWindow.loadSavedFrame()` always returns `nil`. The method exists, `setFrameAutosaveName` is called, but the saved-frame lookup is never implemented. Every launch opens the window at a hard-coded centered position.
- Files: `MDViewer/MarkdownWindow.swift` lines 59–61, 31
- Impact: Users cannot persist window position/size across app launches. Contradicts the `setFrameAutosaveName` call which implies persistence.
- Fix approach: Either implement frame restoration via `NSUserDefaults` (read back the key written by `setFrameAutosaveName`) or remove the dead `frameSaveKey` constant and `loadSavedFrame` method entirely. The simplest fix is to delete both and rely solely on `setFrameAutosaveName`/`setFrame(using:)` which AppKit handles automatically when the key is set before `makeKeyAndOrderFront`.

**All windows share a single `frameSaveKey`:**
- Issue: `frameSaveKey` is a static constant `"MDViewerWindowFrame"`. Opening multiple files writes to the same key, so the last-closed window wins.
- Files: `MDViewer/MarkdownWindow.swift` line 6
- Impact: When multiple files are open simultaneously, window positions conflict.
- Fix approach: Use a per-file autosave key (e.g., based on file path hash) or accept last-write-wins behavior and document it.

**Chunking always produces at most 2 chunks:**
- Issue: `chunkHTML` in `MarkdownRenderer.swift` splits HTML into exactly two segments — content before the 50th block tag, and everything after. For files with hundreds of block elements, the "remaining chunk" is still a single large string injected at once.
- Files: `MDViewer/MarkdownRenderer.swift` lines 153–165
- Impact: For very large documents (e.g. 500+ headings/paragraphs), the second injection via `evaluateJavaScript` passes an extremely large string, potentially stalling the main thread during JS evaluation.
- Fix approach: Implement true N-chunk splitting with configurable chunk size, spreading injections over multiple `setTimeout` calls (the JS in `WebContentView.swift` already supports arrays of chunks via the `i * 16` stagger).

**`MDViewerTests.swift` is an empty placeholder:**
- Issue: `MDViewerTests/MDViewerTests.swift` contains only `testPlaceholder()` which asserts `true`.
- Files: `MDViewerTests/MDViewerTests.swift`
- Impact: No concern for functionality, but creates a misleading second test class that implies a separate test surface.
- Fix approach: Delete the file or move it to a test utilities module.

---

## Known Bugs

**Window position resets on every launch:**
- Symptoms: App always opens at the screen center regardless of where the window was previously placed.
- Files: `MDViewer/MarkdownWindow.swift` lines 13–16, 59–61
- Trigger: Any app launch — `loadSavedFrame()` unconditionally returns `nil`.
- Workaround: None for the user.

**All windows open at the same position (no real cascading):**
- Symptoms: Opening multiple files in one session stacks all windows on top of each other at the same center point.
- Files: `MDViewer/MarkdownWindow.swift` lines 48–57 (`cascadedOrigin`)
- Trigger: Open two or more files simultaneously or in rapid succession.
- Workaround: Manually reposition windows after opening.

---

## Security Considerations

**`CMARK_OPT_UNSAFE` renders raw HTML from markdown input:**
- Risk: cmark-gfm's `CMARK_OPT_UNSAFE` flag passes raw `<script>`, `<iframe>`, and `<style>` tags in markdown directly to the WKWebView without sanitization. A crafted `.md` file could execute arbitrary JavaScript in the webview.
- Files: `MDViewer/MarkdownRenderer.swift` line 67
- Current mitigation: WKWebView runs in a separate process with restricted access. Local file origin limits network requests. No sensitive user data is accessible to the webview.
- Recommendations: For a viewer-only app the risk is low, but consider `CMARK_OPT_SAFE` if the app scope ever expands to remote content or user-shared documents. Document this intentional choice in a comment.

**`developerExtrasEnabled` ships to users:**
- Risk: The WebKit developer console (right-click > Inspect Element) is enabled in production builds via `config.preferences.setValue(true, forKey: "developerExtrasEnabled")`. This exposes the full DOM and JS execution environment to end users.
- Files: `MDViewer/WebContentView.swift` line 22
- Current mitigation: None.
- Recommendations: Gate behind `#if DEBUG` preprocessor condition:
  ```swift
  #if DEBUG
  config.preferences.setValue(true, forKey: "developerExtrasEnabled")
  #endif
  ```

**`public.plain-text` registered as a handled document type:**
- Risk: `Info.plist` lists `public.plain-text` as a supported content type. This means the app can appear in "Open With" for any plain-text file (`.txt`, `.csv`, `.log`, etc.), not just markdown.
- Files: `MDViewer/Info.plist` lines 35, 51
- Current mitigation: `LSHandlerRank` is `Alternate` so the app is not set as default handler.
- Recommendations: Remove `public.plain-text` from `LSItemContentTypes`. Keep only `net.daringfireball.markdown` and the extension list.

**`NSApp.activate(ignoringOtherApps: true)` is deprecated in macOS 14:**
- Risk: Not a security issue per se, but this API was deprecated in macOS 14 Sonoma. It aggressively steals focus from other apps, which violates macOS HIG and may surface a deprecation warning during notarization in future OS versions.
- Files: `MDViewer/AppDelegate.swift` line 15
- Current mitigation: App targets macOS 13, so no crash yet.
- Recommendations: Replace with `NSApp.activate()` (no-argument form, available macOS 14+) behind an availability check, or remove entirely since `makeKeyAndOrderFront` is sufficient.

---

## Performance Bottlenecks

**3 MB mermaid.min.js loaded into every window that contains a diagram:**
- Problem: Mermaid JS is 3.0 MB on disk. It is injected via `evaluateJavaScript(js)` — meaning the full 3 MB string is passed through the Swift/JS bridge each time a document with a Mermaid block is opened.
- Files: `MDViewer/WebContentView.swift` lines 122–136; `MDViewer/Resources/mermaid.min.js`
- Cause: `loadAndInitMermaid()` caches the `String` in a static variable, avoiding disk re-reads, but still pays the bridge-call cost for each window.
- Improvement path: Load Mermaid via a `<script src="...">` tag in `template.html` pointing to the bundled file. WKWebView's resource URL is already set as the base URL (`Bundle.main.resourceURL`), so a relative `src="mermaid.min.js"` will resolve. This avoids the bridge entirely.

**HTML entity encoding/decoding uses O(n) character-by-character loop for Mermaid source:**
- Problem: `encodeHTMLEntities` in `MarkdownRenderer.swift` iterates character-by-character. For large Mermaid graphs this is slow.
- Files: `MDViewer/MarkdownRenderer.swift` lines 138–150
- Cause: Swift `String` character iteration is non-trivial due to Unicode grapheme clusters.
- Improvement path: Use `replacingOccurrences` chained calls (already done in `decodeHTMLEntities`) or a lookup table with `String.reserveCapacity`.

**Mermaid JS loaded from disk on first use, blocking the main thread:**
- Problem: `try? String(contentsOf: url, encoding: .utf8)` is a synchronous disk read called on the main thread inside `loadAndInitMermaid`.
- Files: `MDViewer/WebContentView.swift` lines 125–127
- Cause: No async read path.
- Improvement path: Pre-load the string on `DispatchQueue.global` at startup (similar to template loading), or use the `<script src>` approach above.

---

## Fragile Areas

**`WKUserContentController` retain cycle — `WebContentView` is never released:**
- Files: `MDViewer/WebContentView.swift` lines 24–31
- Why fragile: `contentController.add(self, name: "firstPaint")` adds `WebContentView` as the message handler. `WKUserContentController` holds a **strong** reference to its script message handlers. Because `webView` retains `config.userContentController`, and the controller retains `WebContentView`, a retain cycle forms. There is no `deinit` or `removeScriptMessageHandler` call anywhere in the class.
- Safe modification: Add a `deinit` that calls `webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")`, or use a weak-wrapper proxy object conforming to `WKScriptMessageHandler`.
- Test coverage: No test exercises window/view deallocation.

**`firstPaint` message can arrive after `remainingChunks` is already cleared:**
- Files: `MDViewer/WebContentView.swift` lines 62–69
- Why fragile: If WKWebView fires `DOMContentLoaded` more than once (possible on `loadHTMLString` reload), `injectRemainingChunks` would find `remainingChunks` empty but `hasMermaid` could trigger a second Mermaid injection. The static `mermaidJSLoaded` flag then prevents re-injection, leaving the document without Mermaid rendering.
- Safe modification: Guard `firstPaint` handling with a `hasProcessedFirstPaint` bool flag.

**`injectRemainingChunks` builds JavaScript by manual string construction:**
- Files: `MDViewer/WebContentView.swift` lines 74–103
- Why fragile: HTML content is embedded directly into a JS template literal. The escaping loop handles `\`, `` ` ``, and `$` but does not handle null bytes or Unicode surrogate characters in malformed markdown output. A document with these characters would produce broken or erroring JavaScript.
- Safe modification: Use `WKUserScript` with a JSON-serialized payload via `JSONSerialization` to pass chunks, or use `webView.callAsyncJavaScript` with typed parameters which handles escaping automatically.

**`mermaidJS` and `mermaidJSLoaded` are non-atomic static vars on a class accessed from main thread only — but not annotated:**
- Files: `MDViewer/WebContentView.swift` lines 17–18
- Why fragile: `loadAndInitMermaid()` is currently called only from `userContentController(_:didReceive:)` which is on the main thread, so the statics are safe in practice. But the lack of `@MainActor` or any comment means a future refactor could introduce a data race.
- Safe modification: Annotate `WebContentView` with `@MainActor` or move mermaid caching to a dedicated thread-safe type.

**`fatalError` on missing bundle resource:**
- Files: `MDViewer/AppDelegate.swift` line 97
- Why fragile: If `template.html` is accidentally excluded from the bundle target, the app crashes at launch with no user-visible error.
- Safe modification: Replace with a graceful error dialog or inline fallback template string. The `fatalError` is appropriate for development but not production.

---

## Scaling Limits

**Single-threaded JavaScript injection for very large files:**
- Current capacity: Works fine for documents up to ~200 block elements (single chunk, no injection needed).
- Limit: Documents with 200+ block elements produce a second chunk injected as one `evaluateJavaScript` call. The JS engine blocks the render thread while parsing multi-megabyte HTML strings.
- Scaling path: Implement true N-chunk splitting in `MarkdownRenderer.chunkHTML` and spread injection over `requestAnimationFrame` ticks.

---

## Dependencies at Risk

**`swift-cmark` pinned to a branch (`gfm`), not a tag or commit:**
- Risk: `Package.resolved` pins to a specific commit hash (`924936d`), but `Package.swift` specifies `branch: "gfm"`. Running `swift package update` could pull a breaking upstream change silently.
- Files: `Package.swift` line 8; `MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Impact: Unexpected C API changes in cmark-gfm would cause compilation failure or silent rendering regressions.
- Migration plan: Pin to a specific tag or commit in `Package.swift` (`.exact("0.x.y")` or `.revision("...")`).

**mermaid.min.js is vendored with no version tracking:**
- Risk: The bundled `mermaid.min.js` (3.0 MB) has no version comment or accompanying lockfile entry. There is no way to determine which version of Mermaid is bundled or when it was last updated.
- Files: `MDViewer/Resources/mermaid.min.js`
- Impact: Security fixes and diagram-rendering bug fixes in Mermaid are invisible to the project.
- Migration plan: Add a `// mermaid vX.Y.Z` comment at the top of the file, or track the version in `README.md` / a `THIRD_PARTY_NOTICES` file.

---

## Repository Hygiene

**Compiled app binary committed to the repository:**
- Issue: `MDViewer.app/` (667 KB binary + resources) is not in `.gitignore` and is present as an untracked directory at the repo root.
- Files: `MDViewer.app/` (entire directory)
- Impact: If accidentally committed, it bloats repository history permanently. Binary diffs are opaque.
- Fix: Add `MDViewer.app/` and `*.app/` to `.gitignore`.

**Code coverage raw profile committed:**
- Issue: `default.profraw` (0-byte LLVM coverage file) exists at the repo root and is not gitignored.
- Files: `default.profraw`
- Fix: Add `*.profraw` to `.gitignore`.

**Screenshot committed to repo root:**
- Issue: `Screenshot 2026-04-05 at 10.40.54.png` (97 KB) is in the repo root, not gitignored.
- Files: `Screenshot 2026-04-05 at 10.40.54.png`
- Fix: Move to `docs/` if intentional, or add `Screenshot *.png` to `.gitignore`.

**`.gitignore` does not cover app binaries or profiling artifacts:**
- Files: `.gitignore`
- Missing entries: `*.app/`, `*.profraw`, `*.xcuserstate` (partially covered by `*.xcuserdata`)
- Fix: Add the missing patterns.

---

## Missing Critical Features

**No App Sandbox entitlements:**
- Problem: The app has no `.entitlements` file and is not sandboxed. Without sandboxing, the app cannot be distributed via the Mac App Store and may be flagged during Gatekeeper notarization review.
- Blocks: Mac App Store submission; enterprise distribution policies requiring sandboxed apps.

**No file watcher / auto-reload:**
- Problem: If the source `.md` file is modified by an external editor while MDViewer has it open, the window does not update. There is no `DispatchSourceFileSystemObject` or `FSEventStream` watching the open file.
- Blocks: The core "viewer" use-case where the user edits in one app and previews in MDViewer.

**No dark mode support:**
- Problem: `template.html` hardcodes `color: #333` and `background: #fff` with no `@media (prefers-color-scheme: dark)` rules. On systems in Dark Mode, the webview renders a white page inside a dark chrome window.
- Files: `MDViewer/Resources/template.html` lines 43–47
- Blocks: Basic macOS visual consistency.

---

## Test Coverage Gaps

**`WebContentView` has zero test coverage:**
- What's not tested: JavaScript injection, chunk loading, Mermaid initialization, monospace toggle, print operation.
- Files: `MDViewer/WebContentView.swift`
- Risk: Silent regressions in the JS bridge, chunk escaping bugs, Mermaid initialization failures.
- Priority: High — this is the primary display path.

**`AppDelegate` file-opening paths have zero test coverage:**
- What's not tested: `openFile()` background dispatch, error alert on unreadable file, `application(_:openFile:)` delegate, command-line argument handling.
- Files: `MDViewer/AppDelegate.swift`
- Risk: Regressions in all file-open entry points go undetected.
- Priority: High.

**`MarkdownWindow` initialization has zero test coverage:**
- What's not tested: Window sizing, title assignment, frame autosave key conflicts, fade-in animation.
- Files: `MDViewer/MarkdownWindow.swift`
- Risk: Low for crash, medium for UI regressions.
- Priority: Low.

**Mermaid rendering path is not integration-tested:**
- What's not tested: The full pipeline from `.md` file with a mermaid block through to `mermaid-placeholder` HTML injection and JS initialization.
- Files: `MDViewerTests/MarkdownRendererTests.swift` (partial — only tests placeholder creation, not JS execution)
- Risk: Mermaid blocks silently fall back to plain `<pre><code>` if the JS path breaks.
- Priority: Medium.

---

*Concerns audit: 2026-04-03*
