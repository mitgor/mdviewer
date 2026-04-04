# MDViewer

A fast, native macOS markdown viewer with LaTeX-inspired typography and Mermaid diagram support.

Built for speed — open a `.md` file, read it, close it. First content visible in under 200ms.

## Features

- **LaTeX typography** — Latin Modern Roman font, booktabs-style tables, clean heading hierarchy
- **Mermaid diagrams** — rendered inline, async, with no network dependency
- **Progressive rendering** — first screen appears instantly, remaining content streams in
- **120fps scrolling** — ProMotion support on compatible hardware (M1 Pro and later)
- **Monospace toggle** — `Cmd+M` switches to fixed-width font for tables and structured content
- **Finder-native** — double-click any `.md` file to open, drag onto dock icon, `Cmd+O` file picker

## Requirements

- macOS 13.0+
- Xcode 15+ (to build)

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

AppKit + WKWebView. Markdown is parsed with [cmark-gfm](https://github.com/apple/swift-cmark) (C library, <10ms for large files), converted to HTML, and rendered in a pre-warmed WKWebView with inlined CSS and bundled Mermaid.js.

### Rendering Pipeline

1. **Phase 1** (~100ms) — Parse markdown, inject first ~50 block elements into webview
2. **Phase 2** (async) — Render Mermaid diagrams with fade-in animation
3. **Phase 3** (streamed) — Append remaining content via `requestAnimationFrame`

## License

MIT
