# Phase 12 — Deferred Items

Items discovered during execution that are OUT OF SCOPE for the current plan.
Logged here per the executor's SCOPE BOUNDARY rule.

## Pre-existing test-host hang (Plan 12-01 execution)

- **Symptom:** `xcodebuild test -scheme MDViewer -destination 'platform=macOS'` hangs
  with `MDViewer (<pid>) encountered an error (The test runner hung before
  establishing connection.)` after ~5m40s timeout.
- **Scope check:** Reproduced on `git stash` of Plan 12-01 changes (before the
  Sparkle import, property, or menu item were applied). Pre-existing;
  independent of Plan 12-01 edits.
- **Not caused by:** Sparkle integration. Debug **build** succeeds with zero
  warnings and the app bundle contains exactly one Sparkle.framework with
  both XPC services.
- **Likely cause:** Test host process lifecycle interaction with AppKit
  activation + codesign "Sign to Run Locally" identity inside a git worktree
  on this developer machine. Unrelated to v2.2 work.
- **Action:** None this plan. Phase 12 orchestrator should re-run tests on
  the merged main branch (where the CI pipeline already demonstrates passing
  tests for prior phases); if the hang persists on main, open a separate
  investigation outside Phase 12 scope.
