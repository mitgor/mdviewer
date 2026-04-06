# Technology Stack

**Analysis Date:** 2026-04-03

## Languages

**Primary:**
- Swift 5.9 - All application source code (`MDViewer/*.swift`)

**Secondary:**
- HTML/CSS/JavaScript - Rendering template (`MDViewer/Resources/template.html`)

## Runtime

**Environment:**
- macOS 13.0+ (Ventura minimum deployment target)
- Native macOS application — no server, no browser runtime

**Package Manager:**
- Swift Package Manager (SPM) — dependency resolution via Xcode integration
- Lockfile: `MDViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (present)

## Frameworks

**Core (Apple system frameworks — no version pinning needed):**
- `Cocoa` / `AppKit` — Window management, menus, NSApplication lifecycle (`AppDelegate.swift`, `MarkdownWindow.swift`)
- `WebKit` (`WKWebView`) — HTML rendering engine for markdown display (`WebContentView.swift`)
- `QuartzCore` — Layer-backed views, high-refresh-rate display support (`MarkdownWindow.swift`)
- `Foundation` — File I/O, regex, URL handling (`MarkdownRenderer.swift`)
- `UniformTypeIdentifiers` — UTType for `.md`/`.markdown` file associations (`AppDelegate.swift`)

**Testing:**
- `XCTest` — Unit test framework; test target `MDViewerTests` (`MDViewerTests/MarkdownRendererTests.swift`)

**Build/Dev:**
- Xcode (primary IDE) — `MDViewer.xcodeproj`
- XcodeGen — `project.yml` defines project structure (generates `project.pbxproj`)

## Key Dependencies

**Critical:**
- `swift-cmark` (`gfm` branch, revision `924936d`) — GitHub-flavored Markdown parsing and HTML rendering
  - Source: `https://github.com/apple/swift-cmark.git`
  - Products used: `cmark-gfm`, `cmark-gfm-extensions`
  - Extensions enabled at runtime: `table`, `strikethrough`, `autolink`, `tasklist`
  - Imported directly as C interop in `MDViewer/MarkdownRenderer.swift`

**Bundled (not SPM — vendored into app bundle):**
- `mermaid.min.js` — Diagram rendering library, loaded on-demand from bundle
  - Location: `MDViewer/Resources/mermaid.min.js`
  - Injected into WKWebView via `evaluateJavaScript` only when document contains mermaid blocks

**Bundled Fonts:**
- Latin Modern Roman (regular, bold) — `MDViewer/Resources/fonts/lmroman10-regular.woff2`, `lmroman10-bold.woff2`
- Latin Modern Mono (regular) — `MDViewer/Resources/fonts/lmmono10-regular.woff2`
- Served from bundle's resource URL as base URL for WKWebView

## Configuration

**Environment:**
- No environment variables — fully self-contained native app
- No `.env` files present

**Build:**
- `project.yml` — XcodeGen project definition (deployment target, Swift version, targets, SPM deps)
- `Package.swift` — SPM manifest for `MDViewerDeps` target (used by Xcode to resolve `swift-cmark`)
- `MDViewer/Info.plist` — App bundle metadata: bundle ID `com.mdviewer.app`, version `1.0`, document type associations for `.md`/`.markdown`

## Platform Requirements

**Development:**
- macOS with Xcode
- XcodeGen (optional — `project.yml` present; `project.pbxproj` already generated)
- No Node.js, no Python, no other runtimes required

**Production:**
- macOS 13.0+ (Ventura)
- Distribution: direct `.app` bundle (no App Store entitlements or sandboxing detected)
- Code-signed: `MDViewer.app/Contents/_CodeSignature/CodeResources` present in built app

---

*Stack analysis: 2026-04-03*
