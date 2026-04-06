# External Integrations

**Analysis Date:** 2026-04-03

## APIs & External Services

**None.** MDViewer is a fully offline, self-contained native macOS application. It makes no network requests at runtime. There are no API keys, SDKs for external services, or outbound HTTP calls anywhere in the source.

## Data Storage

**Databases:** None — no SQLite, CoreData, or any database.

**File Storage:** Local filesystem only.
- Reads `.md`/`.markdown` files from disk via `URL(fileURLWithPath:)` and `String(contentsOf:encoding:)`
- `MDViewer/MarkdownRenderer.swift` — `renderFullPage(fileURL:template:)` performs the read
- No writes to disk (read-only viewer)

**Caching:**
- In-memory only: `mermaid.min.js` source string is cached in a static property on `WebContentView` after first load
- Window frame persistence uses `NSWindow.setFrameAutosaveName` (writes to `UserDefaults` automatically via AppKit)

## Authentication & Identity

**Auth Provider:** None — no user accounts, no login, no auth of any kind.

## Monitoring & Observability

**Error Tracking:** None — no Sentry, Crashlytics, or similar.

**Logs:** None configured — errors surface via `NSAlert` modal dialogs to the user (see `AppDelegate.swift` `openFile` error path). No structured logging framework in use.

## CI/CD & Deployment

**Hosting:** Not applicable — distributed as a macOS `.app` bundle.

**CI Pipeline:** None detected — no `.github/workflows/`, no `Makefile`, no CI config files present.

## Environment Configuration

**Required env vars:** None.

**Secrets location:** None — no secrets, API keys, or credentials of any kind.

## Webhooks & Callbacks

**Incoming:** None.

**Outgoing:** None.

## macOS System Integrations

**File Association (OS-level):**
- Registered as a viewer for `net.daringfireball.markdown` and `public.plain-text` UTIs
- Handles `.md` and `.markdown` extensions
- `LSHandlerRank: Alternate` — does not claim ownership, coexists with other Markdown apps
- Declared in `MDViewer/Info.plist` under `CFBundleDocumentTypes` and `UTImportedTypeDeclarations`

**WKWebView JavaScript Bridge:**
- `window.webkit.messageHandlers.firstPaint` — JS-to-Swift message channel for first paint signaling
- `WebContentView` registers as `WKScriptMessageHandler` for the `"firstPaint"` message name
- Swift-to-JS: `evaluateJavaScript` used for chunk injection (`window.appendChunk`), mermaid init (`window.initMermaid`), and monospace toggle (`window.toggleMonospace`)

**Print / PDF Export:**
- Uses `WKWebView.printOperation(with:)` — delegates entirely to macOS print system
- No third-party PDF library; export is handled by AppKit/WebKit natively
- Invoked from `WebContentView.printContent()` called via `AppDelegate.printDocument`

---

*Integration audit: 2026-04-03*
