---
phase: 05-window-management
verified: 2026-04-06T22:30:00Z
status: human_needed
score: 3/3 automated must-haves verified
human_verification:
  - test: "Reopen same file restores saved window position and size"
    expected: "After moving/resizing a window, quitting, and reopening the same file, the window appears at the saved position and size"
    why_human: "Requires running the app, interacting with a window, and observing AppKit frame restoration — cannot verify UserDefaults round-trip via grep"
  - test: "Different files have independent saved positions"
    expected: "Opening a second file does not place its window at the same saved position as the first file's window"
    why_human: "Requires runtime observation of two windows' positions; per-file key correctness proven in code but isolation effect needs visual confirmation"
  - test: "Three simultaneously-opened files produce cascaded windows"
    expected: "Each window is offset ~20px down-right from the previous — no stacking at the same coordinates"
    why_human: "Requires opening multiple files and visually confirming cascadeTopLeft(from:) produces distinct on-screen positions"
---

# Phase 5: Window Management Verification Report

**Phase Goal:** Windows remember their position across launches and multiple windows cascade properly
**Verified:** 2026-04-06T22:30:00Z
**Status:** human_needed (all automated checks passed; runtime behavior needs manual confirmation)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Window position and size are restored when reopening the same file | ? HUMAN_NEEDED | `setFrameAutosaveName(Self.autosaveName(for: fileURL))` called in init with per-file key — AppKit round-trip requires runtime confirmation |
| 2 | Opening multiple files produces cascaded (offset) windows, not stacked | ? HUMAN_NEEDED | `cascadeTopLeft(from: Self.lastCascadePoint)` called for new windows; logic correct but visual offset needs runtime confirmation |
| 3 | Different files have independent saved positions | ✓ VERIFIED | Autosave name format `"MDViewer:\(fileURL.standardizedFileURL.path)"` guarantees unique keys per absolute path — distinct keys proven by code inspection |

**Score:** 1/3 fully automated (Truth 3); 2/3 require runtime confirmation

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MDViewer/MarkdownWindow.swift` | Per-file autosave name and cascade support | ✓ VERIFIED | File exists, 82 lines, substantive implementation — contains `autosaveName(for:)`, `lastCascadePoint`, `setFrameAutosaveName`, `cascadeTopLeft` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `MDViewer/AppDelegate.swift` | `MDViewer/MarkdownWindow.swift` | `MarkdownWindow(fileURL: url, contentView: contentView)` | ✓ WIRED | Line 179 of AppDelegate.swift passes the file URL; MarkdownWindow init receives and uses it for autosave name derivation |
| `MDViewer/MarkdownWindow.swift` | UserDefaults | `setFrameAutosaveName` with per-file key | ✓ WIRED | Line 43 calls `self.setFrameAutosaveName(Self.autosaveName(for: fileURL))` — AppKit handles UserDefaults persistence automatically |

### Data-Flow Trace (Level 4)

Not applicable. This phase produces no component that renders dynamic data — it manages window frame persistence via AppKit's built-in UserDefaults integration. Data flow is AppKit-internal (no custom fetch/query).

### Behavioral Spot-Checks

Step 7b: SKIPPED for automated items — frame persistence and cascading require the app to run with a connected display. The gsd-tools module check is not applicable (no CLI entry point). Manual steps are captured in Human Verification Required section.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| WIN-01 | 05-01-PLAN.md | Window position and size persisted across app launches via `setFrameAutosaveName` | ✓ SATISFIED | `setFrameAutosaveName(Self.autosaveName(for: fileURL))` at line 43 of MarkdownWindow.swift; frame-change detection at lines 42–49 skips cascade when autosave restores a frame |
| WIN-02 | 05-01-PLAN.md | Multiple windows cascade properly instead of stacking at same position | ✓ SATISFIED | `Self.lastCascadePoint = self.cascadeTopLeft(from: Self.lastCascadePoint)` at line 48; static `lastCascadePoint` accumulates across window opens |

No orphaned requirements — REQUIREMENTS.md maps WIN-01 and WIN-02 to Phase 5 and both are claimed in 05-01-PLAN.md.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | — |

No TODO/FIXME/placeholder comments, no empty returns, no stub methods. Removed stubs (`loadSavedFrame`, `cascadedOrigin`, `frameSaveKey`) are confirmed absent.

### Human Verification Required

#### 1. Window Position Persists Across Launches (WIN-01)

**Test:**
1. Build and run MDViewer
2. Open any `.md` file — window appears at default position
3. Move and resize the window to a distinct position (e.g., top-left corner, make it narrow)
4. Quit MDViewer (Cmd+Q)
5. Relaunch and open the SAME file

**Expected:** Window appears at the position and size from step 3, not the default centered position
**Why human:** Requires UserDefaults round-trip through AppKit's frame persistence — cannot simulate app quit/relaunch in a grep check

#### 2. Different Files Have Independent Positions (WIN-01 isolation)

**Test:**
1. After step 5 above, open a DIFFERENT `.md` file

**Expected:** The second file's window does NOT appear at the first file's saved position — it should appear at a default/cascaded position
**Why human:** Requires observing two window positions simultaneously

#### 3. Multi-Window Cascade (WIN-02)

**Test:**
1. Open 3 `.md` files simultaneously (select all 3 in Open dialog or `Cmd+O`)

**Expected:** Three windows appear, each offset roughly 20px down and to the right of the previous — no stacking at identical coordinates
**Why human:** `cascadeTopLeft(from:)` behavior depends on screen geometry and window order; visual confirmation required

### Gaps Summary

No gaps in the code implementation. All plan acceptance criteria pass:

- `grep "autosaveName" MarkdownWindow.swift` — found at lines 43 and 70 (call site + method definition)
- `grep -c "frameSaveKey" MarkdownWindow.swift` — returns 0 (shared key removed)
- `grep "cascadeTopLeft" MarkdownWindow.swift` — found at line 48
- `grep "lastCascadePoint" MarkdownWindow.swift` — found at lines 6 and 48
- `grep "setFrameAutosaveName" MarkdownWindow.swift` — found at line 43, uses `autosaveName` call (not a static string)
- Commit `12f9782` exists and matches the implementation

The human-verify checkpoint (Task 2) was auto-approved per user instruction. Runtime confirmation is the only remaining step.

---

_Verified: 2026-04-06T22:30:00Z_
_Verifier: Claude (gsd-verifier)_
