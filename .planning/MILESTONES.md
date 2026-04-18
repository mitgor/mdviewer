# MDViewer Milestones

| Version | Name | Shipped | Phases | Archive |
|---------|------|---------|--------|---------|
| v2.1 | Deep Optimization | 2026-04-18 | 06–09 | [v2.1-ROADMAP.md](milestones/v2.1-ROADMAP.md) · [v2.1-REQUIREMENTS.md](milestones/v2.1-REQUIREMENTS.md) |
| v2.0 | Speed & Memory | 2026-04-16 | 01–05 | [v2.0-ROADMAP.md](milestones/v2.0-ROADMAP.md) · [v2.0-REQUIREMENTS.md](milestones/v2.0-REQUIREMENTS.md) |

## v2.1 — Deep Optimization

**Shipped:** 2026-04-18 · [Release](https://github.com/mitgor/mdviewer/releases/tag/v2.1) · Notarized DMG

Vendored cmark with a chunked callback API; pre-warmed WKWebView pool with async replenishment and crash recovery; streaming parse-to-render pipeline with buffer-reuse first-page assembly; native NSTextView backend (AST → NSAttributedString) for mermaid/table-free files.

Known deferred items at close: 6 (see [STATE.md Deferred Items](STATE.md)).
