# Roadmap: MDViewer

## Current Milestone

**None active.** v2.1 shipped 2026-04-18 — next milestone not yet defined. Run `/gsd-new-milestone` to scope v2.2 (or v3.0).

## Shipped Milestones

- **v2.1 Deep Optimization** — Phases 06–09, shipped 2026-04-18. See [milestones/v2.1-ROADMAP.md](milestones/v2.1-ROADMAP.md).
- **v2.0 Speed & Memory** — Phases 01–05, shipped 2026-04-16. See [milestones/v2.0-ROADMAP.md](milestones/v2.0-ROADMAP.md).

See [MILESTONES.md](MILESTONES.md) for the index.

---

<details>
<summary>v2.0 Speed & Memory (Phases 1–5) — shipped 2026-04-16</summary>

- [x] **Phase 1: Correctness & Measurement Baseline** — Fix WKWebView retain cycle and add os_signpost instrumentation so all subsequent measurements are valid
- [x] **Phase 2: Large File Memory & Progressive Rendering** — Memory-mapped file reads and true N-chunk progressive rendering for 10MB+ files
- [x] **Phase 3: Launch Speed** — WKWebView pre-warm and sub-100ms warm launch target
- [x] **Phase 4: Mermaid Script Loading** — Replace 3MB evaluateJavaScript bridge call with script-src loading
- [x] **Phase 5: Window Management** — Persistent window positions and proper multi-window cascading

</details>
