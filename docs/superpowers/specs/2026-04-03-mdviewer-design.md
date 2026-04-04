# MDViewer — Native macOS Markdown Viewer

## Overview

A fast, read-only macOS markdown viewer with Mermaid diagram support and LaTeX-inspired typography. Designed as a Finder-native quick preview tool — double-click a `.md` file, read it, close it. Target: first content visible in under 200ms.

## Architecture

**Stack:** AppKit + WKWebView, Swift, cmark-gfm (via SPM).

**Core components:**

| Component | Responsibility |
|---|---|
| `AppDelegate` | App lifecycle, receives file URLs from Finder via `application(_:open:)`, creates windows |
| `MarkdownWindow` | `NSWindow` subclass — minimal chrome, remembers size/position, title shows filename |
| `MarkdownRenderer` | Parses markdown with cmark-gfm, splits output into chunks, wraps in HTML template |
| `WebContentView` | Configures and manages `WKWebView`, handles progressive content injection |
| `template.html` | HTML shell with inlined CSS (LaTeX typography), Mermaid loader, chunk injection JS |

**Data flow:** Finder → `AppDelegate` → `MarkdownRenderer.render(url:)` → HTML chunks → `WebContentView` → WKWebView display.

## Rendering Pipeline — Progressive Loading

### Phase 1: Instant first screen (~100ms)
- Parse full markdown with cmark-gfm (<10ms even for large files)
- Split HTML output after the first ~50 block-level elements (paragraphs, headings, code blocks, lists) as a proxy for one screenful of content
- Inject first chunk into WKWebView with CSS already inlined
- Window appears with styled text immediately

### Phase 2: Mermaid diagrams (async, non-blocking)
- Mermaid code blocks initially render as styled placeholder boxes (light gray with subtle pulse animation)
- After first paint, JS calls `mermaid.run()` on visible diagram blocks first, then off-screen ones
- Each diagram fades in as it renders, replacing its placeholder

### Phase 3: Remaining content (streamed)
- Append remaining HTML chunks via JS (`insertAdjacentHTML`) in batches
- Batches throttled with `requestAnimationFrame` so scrolling stays smooth
- User can scroll into content as it loads — no jank

### Speed Tricks
- **Pre-warm WKWebView** — create and configure the webview at app launch before any file is opened; load the CSS/JS template as a blank page so the engine is hot
- **Fade-in window** — show window only after first content paint (via `WKNavigationDelegate` callback), avoiding white flash
- **Font preload** — embed Latin Modern as base64 data URI in CSS, no font-loading flash
- **CSS-only syntax highlighting** — inject classes during markdown parse, no heavy JS highlighter

## Typography

### LaTeX Style (Default)
- **Body:** Latin Modern Roman (bundled woff2), 16px, line-height 1.6, max-width ~680px centered
- **Headings:** Latin Modern, bold. h1: 2em, h2: 1.5em, h3: 1.25em. Tight letter-spacing.
- **Code blocks:** Latin Modern Mono or SF Mono, slightly smaller, cream/ivory background, thin border
- **Inline code:** Same mono font, subtle background tint
- **Block quotes:** Indented with left border, italic
- **Tables:** Clean ruled lines — top, bottom, under header (LaTeX booktabs style)
- **Links:** Dark blue, no underline until hover

### Monospace Toggle
- `Cmd+M` keyboard shortcut or View → Monospace menu item
- Switches body font to mono, adjusts line-height to 1.5
- Preserves all other styling (headings, spacing, colors)
- Quick fade-out/in transition (~150ms)
- Resets per window, not persisted

### Always Light
- No dark mode. White/cream background, dark text. Matches LaTeX aesthetic.

## Mermaid Diagrams
- Rendered inline, centered, with padding
- Mermaid neutral theme, customized: dark gray lines, white fills, serif font labels to match LaTeX style
- Bundled `mermaid.min.js` — no network dependency
- Malformed Mermaid → falls back to displaying raw code block, no error UI

## File Handling

### Supported Types
- `.md` and `.markdown` extensions
- Declared via UTI in Info.plist (`public.text` conforming)

### Opening Behavior
- Double-click in Finder → opens in new window
- Drag onto dock icon → opens
- Multiple files → multiple windows (one per file)
- `Cmd+O` → file picker filtered to markdown

### App Behavior
- Read-only, no editing
- No recent files, no tabs, no preferences window
- `Cmd+W` closes window
- Last window closed → app quits
- File not found / unreadable → alert dialog

## Project Structure

```
MDViewer/
├── MDViewer.xcodeproj
├── MDViewer/
│   ├── AppDelegate.swift
│   ├── MarkdownWindow.swift
│   ├── WebContentView.swift
│   ├── MarkdownRenderer.swift
│   ├── Resources/
│   │   ├── template.html
│   │   ├── mermaid.min.js
│   │   └── fonts/
│   │       └── lmroman*.woff2
│   └── Info.plist
└── Package.swift
```

## Dependencies
- **cmark-gfm** — GitHub-flavored markdown parsing (Swift Package, C library)
- **Mermaid.js** — diagram rendering (bundled JS, ~1.5MB minified)
- **Latin Modern fonts** — bundled woff2 files

## Non-Goals
- No editing capability
- No dark mode
- No file watching / live reload
- No tabs or multi-document interface
- No preferences / settings persistence
- No export (PDF, HTML, etc.)
