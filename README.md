# MDViewer

A fast, native macOS markdown viewer with LaTeX-inspired typography and Mermaid diagram support.

Built for speed — open a `.md` file, read it, close it. First content visible in under 200ms.

## Features

- **LaTeX typography** — Latin Modern Roman font, booktabs-style tables, clean heading hierarchy
- **Mermaid diagrams** — rendered inline, async, with no network dependency
- **Progressive rendering** — first screen appears instantly, remaining content streams in
- **120fps scrolling** — ProMotion support on compatible hardware (M1 Pro and later)
- **Monospace toggle** — `Cmd+M` switches to fixed-width font for tables and structured content
- **Native rendering mode** — optional AppKit `NSTextView` path (per-window menu toggle) for very large documents or AppKit-native text selection and search
- **Finder-native** — double-click any `.md` file to open, drag onto dock icon, `Cmd+O` file picker

## Install

Download the latest signed and notarized DMG from the [Releases page](https://github.com/mitgor/mdviewer/releases/latest), open it, and drag **MDViewer.app** into `/Applications`.

Universal binary (Apple Silicon + Intel), signed with Developer ID and notarized by Apple — no "unidentified developer" prompt.

## Requirements

- macOS 13.0+
- Xcode 15+ (to build from source)

## Build

```bash
brew install xcodegen   # if not installed
xcodegen generate
xcodebuild build -scheme MDViewer -configuration Release
```

Or open `MDViewer.xcodeproj` in Xcode and hit Run.

## Set as Default Viewer

1. Right-click any `.md` file in Finder
2. Get Info (`Cmd+I`)
3. Under "Open with", select MDViewer
4. Click "Change All..."

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+O` | Open file |
| `Cmd+M` | Toggle monospace |
| `Cmd+W` | Close window |
| `Cmd+Q` | Quit |

## Architecture

AppKit + WKWebView, with an optional native-text rendering path. Markdown is parsed with [cmark-gfm](https://github.com/github/cmark-gfm) (C library, vendored under `Vendor/cmark-gfm`, <10ms for large files). The default path converts the AST to HTML and renders it in a pre-warmed WKWebView with inlined CSS and bundled Mermaid.js; the native path walks the AST into an `NSAttributedString` rendered by `NSTextView`.

### Rendering Pipeline

1. **Phase 1** (~100ms) — Parse markdown, inject first ~50 block elements into webview
2. **Phase 2** (async) — Render Mermaid diagrams with fade-in animation
3. **Phase 3** (streamed) — Append remaining content via `requestAnimationFrame`

## License

MIT
